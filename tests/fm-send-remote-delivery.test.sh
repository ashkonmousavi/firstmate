#!/usr/bin/env bash
# fm-send remote-secondmate delivery: the remote inbox leg.
#
# A remote steer is delivered by durable record, never by typing its payload:
# fm-send crosses fm-on.sh to the host-local leg (fm-remote-secondmate-control.sh
# cmd_send), which writes the message idempotently into the remote home's
# steering inbox and rings the remote doorbell best-effort. These tests drive
# the real fm-send + fm-on executables with a stubbed ssh transport that
# EXECUTES the real host-local leg against a seeded remote-home fixture (the
# FM_SSH_BIN seam tests/fm-on.test.sh proves preserves exit status), and pin:
#   1. A remote text steer lands as a durable record in the remote home's
#      steering inbox, marker and corr token in the body, exits 0, and marks
#      the pending-reply expectation delivered at enqueue; a failed doorbell
#      never fails the send.
#   2. Re-running the identical leg is idempotent: an ambiguous transport
#      (executed remotely, then ssh exit 255) makes fm-send retry the same
#      leg once, and the remote inbox holds exactly ONE record afterwards.
#   3. A remote --resolve-key answer closes its decision at enqueue.
#   4. A remote harness-native "/..." steer also rides the inbox: the deleted
#      remote typed-payload plane is gone for every remote text.
#   5. A real remote failure still fails loudly with the remote leg's own
#      stderr and discards the undelivered expectation.
#   6. The deleted exit-3-as-delivered remap is GONE: a nonzero remote leg
#      status is a failure, never reported as delivered.
#   7. Pure transport loss (ssh 255 twice, nothing executed) fails with
#      resend-safe guidance - the deleted "do not resend" trap is gone - and
#      preserves the marked expectation for the record that may have landed.
#   8. A LOCAL typed-plane send (an explicit backend target or harness-native
#      slash) keeps its exit-3 delivered-unconfirmed contract, never closes a
#      --resolve-key decision unconfirmed, and keeps a marked expectation
#      armed.
#   9. The parent watcher's remote inbox ladder (remote_inbox_tick) re-rings
#      an unacknowledged remote record after grace through the real inbox
#      verb, stays quiet once the record is acknowledged, and after the ring
#      budget queues exactly one stale wake.
#  10. The remote enqueue still deduplicates exactly once the scan only
#      compares same-size records.
# A failing fake herdr shadows any real one, so the executed remote leg's
# doorbell can never reach or start a herdr server on the test machine.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-remote-delivery)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Stub tmux for the local typed-plane legs: logs literal typed text to
# FM_SEND_LOG. The default composer reads empty (clean submit);
# FM_FAKE_TMUX_PENDING=1 keeps a proven pending composer with no busy footer,
# so the real submit core exhausts its Enter budget and reports the pending
# verdict. The ssh stub counts invocations, logs the wire line, and either
# fails with FM_FAKE_SSH_RC (emitting FM_FAKE_SSH_STDERR as the remote
# stderr), or decodes the entrypoint argv and executes the REAL host-local
# command against the decoded remote home - with FM_FAKE_SSH_AMBIGUOUS=1
# reporting ssh exit 255 after that execution (completion unknown, but the
# remote leg actually ran).
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ "${FM_FAKE_TMUX_PENDING:-0}" = 1 ]; then
      printf '╭────────────╮\n│ > steer    │\n╰────────────╯\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows) printf '%s\n' win fm-t2 fm-lsm; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_HERDR_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
[ -n "${FM_FAKE_HERDR_UNCONFIRMED:-}" ] || exit 1
case "${1:-} ${2:-}" in
  'status --json') printf '%s\n' '{"server":{"running":true,"compatible":true},"client":{"protocol":22,"version":"fixture"}}' ;;
  'pane get') printf '%s\n' '{"error":{"code":"unavailable"}}' ;;
  'agent get') printf '%s\n' '{"result":{"agent":{"agent":"pi","agent_status":"unavailable"}}}' ;;
  'pane send-text') printf '%s\n' "$4" >> "$FM_FAKE_HERDR_LOG.typed" ;;
  'pane send-keys') printf '%s\n' "$4" >> "$FM_FAKE_HERDR_LOG.keys" ;;
  'pane read')
    if [ -s "$FM_FAKE_HERDR_LOG.typed" ]; then
      [ "$FM_FAKE_HERDR_UNCONFIRMED" != capture-failure ] || exit 1
      printf 'unreadable composer\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fb/herdr"
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
cat > /dev/null
count=$(cat "$FM_SSH_COUNT" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$FM_SSH_COUNT"
printf '%s\n' "$*" >> "$FM_SSH_LOG"
if [ -n "${FM_FAKE_SSH_HANG:-}" ]; then
  # A busy remote lane: the transport attempt never returns on its own. The
  # real sleep, because the stubbed one on PATH returns immediately.
  /bin/sleep "$FM_FAKE_SSH_HANG"
  exit 255
fi
if [ "${FM_FAKE_SSH_AFTER_AMBIGUOUS_RC:-0}" -ne 0 ] && [ "$count" -gt 1 ]; then
  exit "$FM_FAKE_SSH_AFTER_AMBIGUOUS_RC"
fi
if [ "${FM_FAKE_SSH_RC:-0}" -ne 0 ]; then
  [ -z "${FM_FAKE_SSH_STDERR:-}" ] || printf '%s\n' "$FM_FAKE_SSH_STDERR" >&2
  exit "${FM_FAKE_SSH_RC}"
fi
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2  # host, fm-remote-entrypoint.sh
home_b64=$3
argv_b64=$4
remote_home=$(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$home_b64")
rargs=()
while IFS= read -r -d '' a; do rargs+=("$a"); done \
  < <(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$argv_b64")
cmd=${rargs[0]}
if [ "${FM_FAKE_SSH_FAIL_INBOX_MARKER:-0}" = 1 ] \
  && [ "$cmd" = fm-remote-secondmate-control.sh ] \
  && [ "${rargs[1]:-}" = inbox ] && [ "${rargs[3]:-}" = escalated ]; then
  exit 255
fi
[ "${FM_FAKE_SSH_DELAY:-0}" -eq 0 ] || /bin/sleep "$FM_FAKE_SSH_DELAY"
rc=0
env -i PATH="$PATH" HOME="$HOME" FM_FAKE_HERDR_LOG="${FM_FAKE_HERDR_LOG:-}" \
  FM_FAKE_HERDR_UNCONFIRMED="${FM_FAKE_HERDR_UNCONFIRMED:-}" \
  FM_HOME="$remote_home" FM_ROOT_OVERRIDE="$FM_REMOTE_CODE_ROOT" \
  "$FM_REMOTE_CODE_ROOT/bin/$cmd" "${rargs[@]:1}" || rc=$?
if [ "${FM_FAKE_SSH_AMBIGUOUS:-0}" = 1 ] \
  || { [ "${FM_FAKE_SSH_AFTER_AMBIGUOUS_RC:-0}" -ne 0 ] && [ "$count" -eq 1 ]; }; then
  exit 255
fi
exit "$rc"
SH
  chmod +x "$fb/fake-ssh"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes a fresh home dir with an empty state/
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# A seeded remote secondmate home the executed host-local leg validates and
# writes into: identity marker, Firstmate-checkout shape, and a parent-route
# endpoint record on Herdr in the dedicated fm-remote session.
setup_remote_secondmate_home() {  # <name> -> echoes remote home dir
  local rh="$TMP_ROOT/$1-rhome"
  mkdir -p "$rh/state/parent-route" "$rh/bin"
  printf 'rsm\n' > "$rh/.fm-secondmate-home"
  printf '# remote secondmate home fixture\n' > "$rh/AGENTS.md"
  fm_write_meta "$rh/state/parent-route/rsm.meta" \
    "window=fm-remote:p1" \
    "worktree=-" \
    "project=-" \
    "backend=herdr" \
    "endpoint_task_id=rsm" \
    "harness=claude" \
    "herdr_session=fm-remote" \
    "herdr_workspace_id=w1" \
    "herdr_tab_id=t1" \
    "herdr_pane_id=p1"
  printf '%s\n' "$rh"
}

# A parent home with a remote-secondmate task meta plus the registry row
# fm-on.sh resolves the ssh route from, pointing at <remote-home>.
setup_remote_parent_home() {  # <name> <remote-home> -> echoes home dir
  local home
  home=$(setup_home "$1")
  mkdir -p "$home/data"
  fm_write_meta "$home/state/rsm.meta" \
    "window=fm-remote:p1" \
    "endpoint_task_id=rsm" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "remote_host=remote-mac" \
    "remote_root=/remote/root" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:p1"
  cat > "$home/data/secondmates.md" <<EOF
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: $2; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
  printf '%s\n' "$home"
}

remote_inbox_records() {  # <remote-home>
  find "$1/state/parent-route/rsm.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null
}

# The single non-dot pending-reply record in <home>, or empty.
pending_record() {  # <home>
  find "$1/state/pending-replies" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | head -1
}

drain_out() {  # <home>
  FM_STATE_OVERRIDE="$1/state" "$DRAIN" 2>/dev/null
}

send_env() {  # <fakebin> <parent-home> <ssh-log> [extra env...] -- <cmd...>
  local fb=$1 home=$2 ssh_log=$3
  shift 3
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" \
    FM_SSH_COUNT="$ssh_log.count" FM_REMOTE_CODE_ROOT="$ROOT" \
    "$@"
}

test_remote_steer_lands_in_remote_inbox() {
  local dir fb ssh_log home rhome rc err rec recs body pend
  dir="$TMP_ROOT/remote-inbox"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-inbox)
  home=$(setup_remote_parent_home remote-inbox "$rhome")

  rc=0
  send_env "$fb" "$home" "$ssh_log" \
    "$SEND" rsm "please rename the metric" >"$dir/out" 2>"$dir/err" || rc=$?
  err=$(cat "$dir/err")
  expect_code 0 "$rc" "a durably recorded remote steer must exit 0: $err"
  assert_grep 'fm-remote-entrypoint.sh' "$ssh_log" "the steer should cross the remote transport"
  recs=$(remote_inbox_records "$rhome")
  [ -n "$recs" ] || fail "the steer must land as a record in the remote steering inbox"
  rec=$(printf '%s\n' "$recs" | head -1)
  body=$(cat "$rec")
  case "$body" in
    *"please rename the metric"*) : ;;
    *) fail "the remote record must carry the steer text: $body" ;;
  esac
  printf '%s' "$body" | grep -Eq 'corr=[a-f0-9]{16}' \
    || fail "the remote record must carry the marked request's corr token: $body"
  case "$body" in
    *"$FM_FROMFIRST_MARK"*) : ;;
    *) fail "the remote record must carry the from-firstmate marker: $body" ;;
  esac
  # The doorbell could not reach the fixture pane (no herdr CLI here); that
  # never fails the send, and the notice still names the durable record.
  assert_contains "$err" "durably recorded" \
    "a failed doorbell must be reported as a notice on a durably sent steer"
  assert_not_contains "$err" "error:" "a durably recorded steer must not carry an error report"
  pend=$(pending_record "$home")
  [ -n "$pend" ] || fail "the marked remote steer must keep its pending-reply expectation"
  [ -n "$(grep '^delivered_epoch=' "$pend" | cut -d= -f2-)" ] \
    || fail "a recorded remote steer must mark the expectation delivered at enqueue: $(cat "$pend")"
  [ "$(grep '^phase=' "$pend" | tail -1 | cut -d= -f2-)" = awaiting_report ] \
    || fail "the delivered expectation must await its report: $(cat "$pend")"
  pass "fm-send remote: a text steer lands as a durable remote inbox record and exits 0 at enqueue"
}

test_remote_unreadable_ring_preserves_durable_enqueue() {
  local mode dir fb ssh_log home rhome rc err rec pend
  for mode in unknown capture-failure; do
    dir="$TMP_ROOT/remote-ring-$mode"; mkdir -p "$dir"
    fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
    rhome=$(setup_remote_secondmate_home "remote-ring-$mode")
    home=$(setup_remote_parent_home "remote-ring-$mode" "$rhome")
    rc=0
    send_env "$fb" "$home" "$ssh_log" \
      env FM_FAKE_HERDR_UNCONFIRMED="$mode" FM_FAKE_HERDR_LOG="$dir/herdr.log" \
      "$SEND" rsm "preserve this remote steer" > "$dir/out" 2> "$dir/err" || rc=$?
    err=$(cat "$dir/err")
    expect_code 0 "$rc" "an unreadable remote ring must not fail durable enqueue: $err"
    rec=$(remote_inbox_records "$rhome")
    [ -n "$rec" ] && [ "$(printf '%s\n' "$rec" | wc -l)" -eq 1 ] || fail "the remote ring must preserve exactly one record"
    assert_contains "$(cat "$rec")" 'preserve this remote steer' "the remote inbox must retain its payload"
    assert_contains "$err" 'doorbell NOT delivered' "the remote leg must report an unreadable ring as not delivered"
    assert_contains "$err" 'durably recorded' "the remote notice must preserve enqueue semantics"
    assert_contains "$err" ' reason=' "the remote notice must name the ring step that failed"
    [ "$(wc -l < "$dir/herdr.log.typed")" -eq 1 ] || fail "the remote leg must type its doorbell only once"
    assert_not_contains "$(cat "$dir/herdr.log.typed")" 'preserve this remote steer' "the remote payload must never be typed"
    pend=$(pending_record "$home")
    [ -n "$pend" ] || fail "a remote ring failure must preserve its reply expectation"
    [ "$(grep '^phase=' "$pend" | tail -1 | cut -d= -f2-)" = awaiting_report ] || fail "durable enqueue must commit reply delivery despite an unreadable ring"
    pass "fm-send remote: $mode reports ring non-delivery and preserves durable enqueue"
  done
}

test_remote_rerun_is_idempotent() {
  local dir fb ssh_log home rhome rc err count pend corr expected_cmd arg quoted rec ssh_before resend_cmd
  dir="$TMP_ROOT/remote-idem"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-idem)
  home=$(setup_remote_parent_home remote-idem "$rhome")

  # Ambiguous transport: the remote leg executes for real, then ssh reports
  # 255 (completion unknown). fm-send retries the identical leg once; the
  # idempotent remote write must land both executions on the same record.
  rc=0
  (
    cd "$TMP_ROOT" || exit 1
    send_env "$fb" "${home#"$TMP_ROOT/"}" "$ssh_log" FM_FAKE_SSH_AMBIGUOUS=1 \
      "$SEND" rsm "please rename the metric"
  ) >"$dir/out" 2>"$dir/err" || rc=$?
  err=$(cat "$dir/err")
  [ "$rc" -ne 0 ] || fail "a twice-lost transport must not claim confirmed delivery"
  [ "$(cat "$ssh_log.count")" = 2 ] \
    || fail "fm-send must retry the identical remote leg exactly once after ssh 255, got $(cat "$ssh_log.count") attempts"
  count=$(remote_inbox_records "$rhome" | grep -c . || true)
  [ "$count" = 1 ] \
    || fail "re-running the remote leg must dedup onto one record, found $count:"$'\n'"$(remote_inbox_records "$rhome")"
  assert_contains "$err" "Only the correlation-reusing resend below is idempotent" \
    "an unconfirmed remote steer must limit resend safety to correlation reuse"
  assert_not_contains "$err" "do not resend" \
    "the deleted do-not-resend trap must be gone for an unconfirmed remote steer"
  pend=$(pending_record "$home")
  [ -n "$pend" ] || fail "an unconfirmed remote steer must preserve its expectation for the record that may have landed"
  [ "$(grep '^phase=' "$pend" | tail -1 | cut -d= -f2-)" = delivery_unknown ] \
    || fail "the preserved expectation must record unknown delivery: $(cat "$pend")"
  corr=$(fm_pending_reply_get "$pend" corr_id)
  printf -v quoted '%q' "$home"
  expected_cmd="FM_HOME=$quoted FM_PENDING_REPLY_EXISTING_CORR=$corr"
  for arg in "$SEND" rsm "please rename the metric"; do
    printf -v quoted '%q' "$arg"
    expected_cmd="$expected_cmd $quoted"
  done
  assert_contains "$err" "$expected_cmd" \
    "double transport loss must print the exact correlation-reusing resend command"

  # A delivered record escalated for a missed report is genuinely stale: the
  # request reached the mate, so the same correlation must never be resent.
  fm_pending_reply_set "$pend" delivered_epoch 4242 \
    || fail "could not mark the fixture expectation delivered"
  fm_pending_reply_set "$pend" phase escalated \
    || fail "could not advance the delivered expectation to the escalated fixture phase"
  ssh_before=$(cat "$ssh_log.count")
  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$SEND" rsm "please rename the metric" >"$dir/stale-resend.out" 2>"$dir/stale-resend.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "an explicitly requested non-reusable correlation must fail closed"
  assert_contains "$(cat "$dir/stale-resend.err")" "refusing to mint a replacement correlation" \
    "a stale explicit correlation must explain that no replacement was minted"
  [ "$(cat "$ssh_log.count")" = "$ssh_before" ] \
    || fail "a stale explicit correlation reached the remote transport"
  [ "$(find "$home/state/pending-replies" -maxdepth 1 -type f ! -name '.*' | wc -l | tr -d ' ')" = 1 ] \
    || fail "a stale explicit correlation minted a replacement expectation"
  [ "$(find "$rhome/state/parent-route/rsm.inbox" -name '*.msg' | wc -l | tr -d ' ')" = 1 ] \
    || fail "a stale explicit correlation created another remote record"
  # The watcher escalates an unknown delivery as soon as it sees it, so the
  # printed resend routinely meets an escalated but still undelivered record;
  # that record stays the owner's to resend under the same correlation.
  fm_pending_reply_set "$pend" delivered_epoch "" \
    || fail "could not restore the undelivered fixture expectation"
  [ "$(fm_pending_reply_get "$pend" phase)" = escalated ] \
    || fail "the undelivered fixture expectation must remain escalated before the resend"

  resend_cmd=$(tail -1 "$dir/err")
  rc=0
  (
    unset FM_HOME
    env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_SEND_SETTLE=0 \
      FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" \
      FM_SSH_COUNT="$ssh_log.count" FM_REMOTE_CODE_ROOT="$ROOT" \
      bash -c "$resend_cmd"
  ) >"$dir/resend.out" 2>"$dir/resend.err" || rc=$?
  expect_code 0 "$rc" "the printed correlation-reusing resend must succeed without an inherited FM_HOME"
  count=$(find "$rhome/state/parent-route/rsm.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "the correlation-reusing resend must leave exactly one remote record, found $count"
  rec=$(find "$rhome/state/parent-route/rsm.inbox" -name '*.msg' | head -1)
  grep -F "corr=$corr" "$rec" >/dev/null \
    || fail "the deduplicated remote record did not preserve correlation $corr"
  [ -n "$(fm_pending_reply_get "$pend" delivered_epoch)" ] \
    || fail "the successful resend did not confirm pending-reply delivery: $(cat "$pend")"
  [ "$(fm_pending_reply_get "$pend" phase)" = awaiting_report ] \
    || fail "the successful resend did not restore awaiting_report: $(cat "$pend")"
  pass "fm-send remote: the printed correlation-reusing resend deduplicates onto the same record"
}

test_remote_retry_failure_preserves_ambiguous_expectation() {
  local dir fb ssh_log home rhome rc err pend
  dir="$TMP_ROOT/remote-ambiguous-then-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-ambiguous-then-fail)
  home=$(setup_remote_parent_home remote-ambiguous-then-fail "$rhome")

  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_AFTER_AMBIGUOUS_RC=1 \
    "$SEND" rsm "please rename the metric" >"$dir/out" 2>"$dir/err" || rc=$?
  err=$(cat "$dir/err")
  [ "$rc" -ne 0 ] || fail "a failed retry after unknown completion must not claim delivery"
  assert_contains "$err" "first transport attempt had unknown completion" \
    "the final error must retain the first attempt's ambiguous completion"
  pend=$(pending_record "$home")
  [ -n "$pend" ] || fail "an ambiguous first attempt must preserve its expectation when the retry fails"
  [ "$(grep '^phase=' "$pend" | tail -1 | cut -d= -f2-)" = delivery_unknown ] \
    || fail "the ambiguous expectation must remain delivery_unknown after a failed retry: $(cat "$pend")"
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 1 ] \
    || fail "the first attempt's durable record must remain the sole remote record"
  pass "fm-send remote: a failed retry cannot erase an earlier ambiguous delivery"
}

test_remote_fire_and_forget_never_arms_reply_recovery() {
  local dir fb ssh_log home rhome rc count delivery action
  dir="$TMP_ROOT/remote-fire-and-forget"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-fire-and-forget)
  home=$(setup_remote_parent_home remote-fire-and-forget "$rhome")
  delivery=0123456789abcdef

  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_AFTER_AMBIGUOUS_RC=1 \
    "$SEND" rsm --fire-and-forget "$delivery" "reconcile your own books" \
    >"$dir/out" 2>"$dir/err" || rc=$?
  expect_code 3 "$rc" "an ambiguous fire-and-forget delivery must report unconfirmed"
  [ "$(find "$home/state/pending-replies" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
    || fail "fire-and-forget delivery created a pending-reply expectation"
  count=$(find "$rhome/state/parent-route/rsm.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "the ambiguous fire-and-forget delivery did not land exactly once"
  action=$(FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    fm_task_inbox_due_action "$rhome/state/parent-route" rsm)
  [ "$action" = quiet ] || fail "the remote fire-and-forget record armed inbox escalation: $action"

  send_env "$fb" "$home" "$ssh_log" \
    "$SEND" rsm --fire-and-forget "$delivery" "reconcile your own books" \
    >"$dir/retry.out" 2>"$dir/retry.err" \
    || fail "the fire-and-forget retry failed"
  count=$(find "$rhome/state/parent-route/rsm.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "the same fire-and-forget delivery id created a duplicate remote record"
  grep -F "delivery=$delivery" "$(remote_inbox_records "$rhome" | head -1)" >/dev/null \
    || fail "the remote record omitted its fire-and-forget delivery identity"
  pass "fm-send remote: fire-and-forget delivery is idempotent without reply recovery"
}

test_remote_send_revalidates_after_retirement_lock() {
  local dir rhome meta lock ready release rc sender_pid holder_pid
  dir="$TMP_ROOT/remote-retire-race"; mkdir -p "$dir"
  rhome=$(setup_remote_secondmate_home remote-retire-race)
  meta="$rhome/state/parent-route/rsm.meta"
  lock="$rhome/state/parent-route/.meta-rsm.lock"
  ready="$dir/lock-ready"
  release="$dir/release-lock"
  FM_STATE_OVERRIDE="$rhome/state/parent-route" bash -c '
    . "$1"
    fm_task_inbox_lock_acquire "$2" || exit 91
    : > "$3"
    while [ ! -e "$4" ]; do sleep 0.05; done
    rm -f "$5"
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$lock" "$ready" "$release" "$meta" &
  holder_pid=$!
  while [ ! -e "$ready" ]; do kill -0 "$holder_pid" 2>/dev/null || fail "metadata-lock holder exited early"; sleep 0.05; done

  rc=0
  env FM_HOME="$rhome" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" send rsm "retirement-race steer" \
    >"$dir/out" 2>"$dir/err" &
  sender_pid=$!
  sleep 0.2
  : > "$release"
  wait "$sender_pid" || rc=$?
  wait "$holder_pid" || fail "metadata-lock holder failed"
  [ "$rc" -ne 0 ] || fail "a send must not enqueue after endpoint retirement won the metadata lock"
  [ -z "$(remote_inbox_records "$rhome")" ] \
    || fail "a send re-created an orphan inbox after endpoint retirement"
  pass "remote control: send revalidates endpoint ownership under the metadata lock"
}

test_remote_send_revalidates_parent_route_after_retirement_lock() {
  local dir fb ssh_log home rhome meta lock ready release rc sender_pid holder_pid
  dir="$TMP_ROOT/remote-parent-retire-race"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-parent-retire-race)
  home=$(setup_remote_parent_home remote-parent-retire-race "$rhome")
  meta="$home/state/rsm.meta"
  lock="$home/state/.meta-rsm.lock"
  ready="$dir/lock-ready"
  release="$dir/release-lock"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_task_inbox_lock_acquire "$2" || exit 91
    : > "$3"
    while [ ! -e "$4" ]; do sleep 0.05; done
    rm -f "$5"
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$lock" "$ready" "$release" "$meta" &
  holder_pid=$!
  while [ ! -e "$ready" ]; do kill -0 "$holder_pid" 2>/dev/null || fail "parent metadata-lock holder exited early"; sleep 0.05; done

  rc=0
  send_env "$fb" "$home" "$ssh_log" \
    "$SEND" rsm "parent-retirement-race steer" >"$dir/out" 2>"$dir/err" &
  sender_pid=$!
  sleep 0.2
  : > "$release"
  wait "$sender_pid" || rc=$?
  wait "$holder_pid" || fail "parent metadata-lock holder failed"
  [ "$rc" -ne 0 ] || fail "a remote send must not enqueue after parent retirement won the metadata lock"
  [ -z "$(remote_inbox_records "$rhome")" ] \
    || fail "a remote send enqueued after its parent route retired"
  [ -z "$(pending_record "$home")" ] \
    || fail "a parent-route retirement failure left a created pending expectation"
  pass "fm-send remote: enqueue revalidates the parent route under its metadata lock"
}

test_remote_expected_host_revalidates_final_route() {
  local dir fb ssh_log home rhome rc err count
  dir="$TMP_ROOT/remote-expected-host"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-expected-host)
  home=$(setup_remote_parent_home remote-expected-host "$rhome")

  rc=0
  send_env "$fb" "$home" "$ssh_log" \
    FM_SEND_EXPECTED_SPAWN_GEN="" FM_SEND_EXPECTED_REMOTE_HOST=remote-mac \
    "$SEND" rsm --fire-and-forget 1111111111111111 "matching expected host" \
    >"$dir/match.out" 2>"$dir/match.err" || rc=$?
  expect_code 0 "$rc" "a matching expected remote host must allow delivery"
  count=$(remote_inbox_records "$rhome" | grep -c . || true)
  [ "$count" = 1 ] || fail "a matching expected remote host did not deliver exactly once"

  rc=0
  send_env "$fb" "$home" "$ssh_log" \
    FM_SEND_EXPECTED_SPAWN_GEN="" FM_SEND_EXPECTED_REMOTE_HOST=retired-mac \
    "$SEND" rsm --fire-and-forget 2222222222222222 "stale expected host" \
    >"$dir/mismatch.out" 2>"$dir/mismatch.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a mismatched expected remote host reported delivery"
  err=$(cat "$dir/mismatch.err")
  assert_contains "$err" "retired or changed route" \
    "a mismatched expected remote host did not report the route replacement: $err"
  count=$(remote_inbox_records "$rhome" | grep -c . || true)
  [ "$count" = 1 ] || fail "a mismatched expected remote host reached the remote inbox"
  pass "fm-send remote: expected host is enforced by final route validation"
}

test_remote_resolve_key_closes_at_enqueue() {
  local dir fb ssh_log home rhome rc out
  dir="$TMP_ROOT/remote-key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-key)
  home=$(setup_remote_parent_home remote-key "$rhome")
  printf 'needs-decision [key=upgrade-window]: tonight or the weekend\n' > "$home/state/rsm.status"

  rc=0
  send_env "$fb" "$home" "$ssh_log" \
    "$SEND" rsm --resolve-key upgrade-window "the weekend, freeze Friday" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "a durably recorded remote answer must exit 0"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/rsm.status" | grep -qF 'resolved [key=upgrade-window]: answered: the weekend, freeze Friday' \
    || fail "a recorded remote answer must close the decision at enqueue: $(cat "$home/state/rsm.status")"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered decision still lists as open after a recorded remote answer: $out"
  fi
  grep -rqF 'the weekend, freeze Friday' "$rhome/state/parent-route/rsm.inbox" \
    || fail "the remote answer must land in the remote steering inbox"
  pass "fm-send remote: a --resolve-key answer closes its decision at enqueue"
}

test_remote_slash_rides_inbox() {
  local dir fb ssh_log home rhome rc recs
  dir="$TMP_ROOT/remote-slash"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-slash)
  home=$(setup_remote_parent_home remote-slash "$rhome")

  rc=0
  send_env "$fb" "$home" "$ssh_log" \
    "$SEND" rsm "/audit the ledger" >/dev/null 2>"$dir/err" || rc=$?
  expect_code 0 "$rc" "a remote harness-native steer must ride the inbox and exit 0"
  recs=$(remote_inbox_records "$rhome")
  [ -n "$recs" ] || fail "a remote '/' steer must land in the remote steering inbox, not a typed plane"
  grep -rqF '/audit the ledger' "$rhome/state/parent-route/rsm.inbox" \
    || fail "the remote record must carry the harness-native text verbatim"
  pass "fm-send remote: every remote text, harness-native included, rides the inbox"
}

test_remote_real_failure_still_fails() {
  local dir fb ssh_log home rhome rc err
  dir="$TMP_ROOT/remote-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-fail)
  home=$(setup_remote_parent_home remote-fail "$rhome")

  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_RC=1 \
    FM_FAKE_SSH_STDERR='error: remote secondmate rsm endpoint metadata is invalid; refusing access until it is explicitly migrated' \
    "$SEND" rsm "please rename the metric" >"$dir/out" 2>"$dir/err" || rc=$?
  err=$(cat "$dir/err")
  [ "$rc" -ne 0 ] || fail "a genuinely failed remote send must exit nonzero"
  assert_contains "$err" "steer not sent to remote secondmate rsm" \
    "a real remote failure must still report a real error"
  assert_contains "$err" "endpoint metadata is invalid" \
    "a real remote failure must surface the remote leg's own stderr"
  [ -z "$(pending_record "$home")" ] \
    || fail "a failed send must discard its undelivered expectation"
  [ -z "$(remote_inbox_records "$rhome")" ] \
    || fail "a refused remote leg must leave no inbox record"
  pass "fm-send remote: a real remote failure still fails loudly with the remote diagnostics"
}

test_remote_exit3_no_longer_delivered() {
  local dir fb ssh_log home rhome rc err
  dir="$TMP_ROOT/remote-exit3"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-exit3)
  home=$(setup_remote_parent_home remote-exit3 "$rhome")

  # The typed-plane remote transport remapped a leg exit 3 to "delivered with
  # confirmation pending". That transport is deleted: any nonzero remote leg
  # status is a failure, never a delivery claim.
  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_RC=3 \
    "$SEND" rsm "please rename the metric" >"$dir/out" 2>"$dir/err" || rc=$?
  err=$(cat "$dir/err")
  [ "$rc" -ne 0 ] || fail "a nonzero remote leg must no longer be remapped to delivered"
  assert_not_contains "$err" "delivered to remote secondmate" \
    "the deleted exit-3-as-delivered remap must be gone"
  assert_contains "$err" "steer not sent to remote secondmate rsm" \
    "a failed remote leg must report the steer as not sent"
  [ -z "$(pending_record "$home")" ] \
    || fail "a failed remote leg must discard its undelivered expectation"
  pass "fm-send remote: exit 3 from the remote leg is a failure, never a delivery claim"
}

test_remote_transport_loss_preserves_expectation() {
  local dir fb ssh_log home rhome rc err pend
  dir="$TMP_ROOT/remote-255"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-255)
  home=$(setup_remote_parent_home remote-255 "$rhome")

  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_RC=255 \
    "$SEND" rsm "please rename the metric" >"$dir/out" 2>"$dir/err" || rc=$?
  err=$(cat "$dir/err")
  [ "$rc" -ne 0 ] || fail "an unknown-completion transport loss must exit nonzero"
  [ "$(cat "$ssh_log.count")" = 2 ] \
    || fail "fm-send must retry the identical remote leg once on ssh 255, got $(cat "$ssh_log.count") attempts"
  assert_contains "$err" "Only the correlation-reusing resend below is idempotent" \
    "transport loss must print the supported safe resend boundary"
  assert_not_contains "$err" "do not resend" \
    "the deleted do-not-resend trap must be gone for transport loss"
  pend=$(pending_record "$home")
  [ -n "$pend" ] || fail "transport loss must preserve the expectation for reconciliation"
  [ "$(grep '^phase=' "$pend" | tail -1 | cut -d= -f2-)" = delivery_unknown ] \
    || fail "transport loss must move the expectation to delivery_unknown: $(cat "$pend")"
  pass "fm-send remote: ssh 255 fails with resend-safe guidance and preserves the expectation"
}

test_remote_send_budget_bounds_busy_lane() {
  local dir fb ssh_log home rhome rc err began elapsed count pend delivery corr ssh_before
  dir="$TMP_ROOT/remote-budget"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-budget)
  home=$(setup_remote_parent_home remote-budget "$rhome")
  delivery=aaaabbbbccccdddd

  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_SEND_REMOTE_BUDGET=invalid \
    "$SEND" rsm --key Enter >"$dir/key-invalid.out" 2>"$dir/key-invalid.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "an invalid remote key budget must fail"
  assert_contains "$(cat "$dir/key-invalid.err")" "must be a positive integer" \
    "an invalid remote key budget must explain its validation failure"
  [ ! -f "$ssh_log.count" ] || fail "an invalid remote key budget reached the transport"

  began=$(date +%s)
  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_HANG=60 FM_SEND_REMOTE_BUDGET=2 \
    "$SEND" rsm --key Enter >"$dir/key.out" 2>"$dir/key.err" || rc=$?
  elapsed=$(( $(date +%s) - began ))
  expect_code 1 "$rc" "a bounded remote key must preserve the existing failure contract"
  [ "$elapsed" -le 15 ] || fail "the bounded remote key waited ${elapsed}s behind the busy lane"
  assert_contains "$(cat "$dir/key.err")" "completion may be unknown" \
    "a bounded remote key failure must preserve its existing diagnostic"
  [ "$(cat "$ssh_log.count")" = 1 ] \
    || fail "a bounded remote key must make exactly one transport attempt"
  printf '0\n' > "$ssh_log.count"

  # T5: a fire-and-forget send to a mate behind a busy lane returns its
  # unconfirmed result within its own budget instead of waiting the lane out.
  began=$(date +%s)
  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_HANG=60 FM_SEND_REMOTE_BUDGET=2 \
    "$SEND" rsm --fire-and-forget "$delivery" "reconcile your own books" \
    >"$dir/out" 2>"$dir/err" || rc=$?
  elapsed=$(( $(date +%s) - began ))
  err=$(cat "$dir/err")
  expect_code 3 "$rc" "a budget-bounded fire-and-forget send must report unconfirmed: $err"
  [ "$elapsed" -le 15 ] || fail "the bounded send waited ${elapsed}s behind the busy lane"
  assert_contains "$err" "delivery-id=$delivery" \
    "the bounded unconfirmed result must name the reusable delivery id"
  [ "$(cat "$ssh_log.count")" = 1 ] \
    || fail "a budget hit must not retry into the same busy lane, got $(cat "$ssh_log.count") attempts"

  # A retry with the same delivery id against the recovered lane dedups onto
  # the same remote record.
  send_env "$fb" "$home" "$ssh_log" \
    "$SEND" rsm --fire-and-forget "$delivery" "reconcile your own books" \
    >"$dir/retry.out" 2>"$dir/retry.err" \
    || fail "the same-delivery-id retry after the budget hit failed"
  count=$(remote_inbox_records "$rhome" | grep -c . || true)
  [ "$count" = 1 ] || fail "the same-delivery-id retry did not dedup onto one record, found $count"

  # A reply-bearing send names the budget and prints the correlation-reusing
  # resend command, with the expectation preserved as delivery-unknown.
  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_HANG=60 FM_SEND_REMOTE_BUDGET=2 \
    "$SEND" rsm "please rename the metric" >"$dir/reply.out" 2>"$dir/reply.err" || rc=$?
  err=$(cat "$dir/reply.err")
  [ "$rc" -ne 0 ] || fail "a budget-bounded reply-bearing send must not claim confirmed delivery"
  assert_contains "$err" "within its 2s budget" \
    "the budget-bounded failure must name the budget that bounded it"
  assert_contains "$err" "Only the correlation-reusing resend below is idempotent" \
    "the budget-bounded failure must print the supported safe resend boundary"
  pend=$(pending_record "$home")
  [ -n "$pend" ] || fail "a budget-bounded reply-bearing send must preserve its expectation"
  [ "$(grep '^phase=' "$pend" | tail -1 | cut -d= -f2-)" = delivery_unknown ] \
    || fail "the preserved expectation must record unknown delivery: $(cat "$pend")"

  # Invalid transport configuration fails before a correlation-reusing resend
  # mutates the preserved expectation or reaches the transport.
  corr=$(fm_pending_reply_get "$pend" corr_id)
  cp "$pend" "$dir/pending-before-invalid-budget"
  ssh_before=$(cat "$ssh_log.count")
  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_SEND_REMOTE_BUDGET=invalid \
    FM_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$SEND" rsm "please rename the metric" >"$dir/invalid.out" 2>"$dir/invalid.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "an invalid remote budget must fail the resend"
  assert_contains "$(cat "$dir/invalid.err")" "must be a positive integer" \
    "an invalid remote budget must explain its validation failure"
  [ "$(cat "$ssh_log.count")" = "$ssh_before" ] \
    || fail "an invalid remote budget reached the remote transport"
  cmp -s "$dir/pending-before-invalid-budget" "$pend" \
    || fail "an invalid remote budget mutated the reusable pending expectation: $(cat "$pend")"
  pass "fm-send remote: the remote leg is budget-bounded and stays idempotent across the bound"
}

test_local_secondmate_pending_keeps_expectation_armed() {
  local dir fb log home rc rec corr
  dir="$TMP_ROOT/local-pending-expectation"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home local-pending-expectation)
  fm_write_meta "$home/state/lsm.meta" \
    "window=sess:fm-lsm" "harness=claude" "kind=secondmate" "mode=secondmate" "home=$home/sm"

  # A harness-native slash invocation keeps the typed plane for a LOCAL marked
  # secondmate target, so this pins the kept armed-expectation semantics there.
  : > "$log"
  rc=0
  env PATH="$fb:$PATH" FM_FAKE_TMUX_PENDING=1 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lsm "/audit the ledger" >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "an unconfirmed local secondmate submit must exit delivered-unconfirmed"
  rec=$(pending_record "$home")
  [ -n "$rec" ] \
    || fail "the pending-reply expectation must survive an unconfirmed local secondmate send"
  [ "$(fm_pending_reply_get "$rec" phase)" = awaiting_report ] \
    || fail "the surviving expectation must stay armed, got $(fm_pending_reply_get "$rec" phase)"
  # Armed means resolvable: the mate's correlated report still closes it.
  corr=$(fm_pending_reply_get "$rec" corr_id)
  printf 'done [corr=%s]: ledger clean\n' "$corr" > "$home/state/lsm.status"
  fm_pending_reply_try_resolve "$home/state" "$corr" \
    || fail "a correlated report must still resolve the preserved expectation"
  pass "fm-send local: an unconfirmed secondmate send keeps its reply expectation armed"
}

test_local_pending_reports_delivered_unconfirmed() {
  local dir fb log home rc err
  dir="$TMP_ROOT/local-pending"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home local-pending)

  # An explicit backend target is the typed plane, so the exit-3 ladder still
  # governs it.
  : > "$log"
  rc=0
  env PATH="$fb:$PATH" FM_FAKE_TMUX_PENDING=1 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:win "steer text" >"$dir/out" 2>"$dir/err" || rc=$?
  err=$(cat "$dir/err")
  expect_code 3 "$rc" "an unconfirmed local submit must exit with the delivered-unconfirmed status"
  assert_contains "$err" "submission is unconfirmed" \
    "the unconfirmed local submit must be described honestly"
  assert_not_contains "$err" "not submitted" \
    "an unconfirmed local submit must not claim the text was not submitted"
  assert_not_contains "$err" "error:" \
    "an unconfirmed local submit must not carry an error-styled report"
  pass "fm-send local: an unconfirmed submit exits 3 with an honest non-error report"
}

test_local_pending_does_not_close_resolve_key() {
  local dir fb log home rc out
  dir="$TMP_ROOT/local-pending-key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home local-pending-key)
  fm_write_meta "$home/state/t2.meta" "window=sess:fm-t2" "kind=ship"
  printf 'blocked [key=creds]: need the deploy token\n' > "$home/state/t2.status"

  # A harness-native slash answer keeps the typed plane, so the unconfirmed
  # ladder still governs it; a plain-text answer would close at enqueue instead.
  : > "$log"
  rc=0
  env PATH="$fb:$PATH" FM_FAKE_TMUX_PENDING=1 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t2 --resolve-key creds "/vault fetch deploy-token" >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "an unconfirmed local answer must exit with the delivered-unconfirmed status"
  if grep -F 'resolved' "$home/state/t2.status" >/dev/null; then
    fail "an unconfirmed local answer must not close the decision: $(cat "$home/state/t2.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=creds]' >/dev/null \
    || fail "the blocker must stay open after an unconfirmed local answer: $out"
  pass "fm-send local: an unconfirmed submit still never closes a --resolve-key decision"
}

# One parent remote_inbox_tick, run as the watcher would after the tick's
# cadence marker has aged out. wake() exits, so each run is its own process.
remote_inbox_tick_env() {  # <fakebin> <parent-home> <ssh-log> [extra env...]
  local fb=$1 home=$2 ssh_log=$3
  shift 3
  rm -f "$home/state/.remote-inbox-tick"
  # shellcheck disable=SC2016 # positional params expand in the child shell.
  send_env "$fb" "$home" "$ssh_log" FM_STATE_OVERRIDE="$home/state" \
    FM_TASK_INBOX_GRACE_SECS=1 "$@" \
    bash -c '. "$1" && remote_inbox_tick' _ "$WATCH"
}

# One watcher-cycle call of remote_inbox_detached under the same environment;
# <snippet> runs after sourcing the watcher.
remote_inbox_detached_env() {  # <fakebin> <parent-home> <ssh-log> <snippet> [extra env...]
  local fb=$1 home=$2 ssh_log=$3 snippet=$4
  shift 4
  send_env "$fb" "$home" "$ssh_log" FM_STATE_OVERRIDE="$home/state" \
    FM_TASK_INBOX_GRACE_SECS=1 "$@" \
    bash -c ". \"\$1\"; $snippet" _ "$WATCH"
}

remote_ring_count() {  # <remote-home>
  cut -f2 "$1/state/parent-route/rsm.inbox/.ring-state" 2>/dev/null || printf '0'
}

remote_hops() {  # <ssh-log> <action>
  local n=0 line
  while IFS= read -r line; do
    case "$line" in *" $2"*) n=$((n + 1)) ;; esac
  done < <(perl -MMIME::Base64=decode_base64 -ne 'for (split / /) { my $d = decode_base64($_); next unless $d =~ /\x00inbox\x00/; $d =~ tr/\x00/ /; print "$d\n" }' "$1")
  printf '%s' "$n"
}

test_remote_inbox_ladder_rerings_unacknowledged_record() {
  local dir fb ssh_log home rhome rec out
  dir="$TMP_ROOT/remote-rering"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-rering)
  home=$(setup_remote_parent_home remote-rering "$rhome")
  rec=$(fm_task_inbox_write_idempotent "$rhome/state/parent-route" rsm "please rename the metric") \
    || fail "could not seed the remote inbox record"
  perl -e 'utime time-5, time-5, $ARGV[0] or die $!' "$rec"

  out=$(remote_inbox_tick_env "$fb" "$home" "$ssh_log" FM_FAKE_HERDR_LOG="$dir/herdr.log" 2>&1) \
    || fail "a healthy re-ring must not fail or wake the watcher: $out"
  [ "$(remote_ring_count "$rhome")" = 1 ] \
    || fail "an unacknowledged remote record past grace must spend one ring attempt, ladder: $(cat "$rhome/state/parent-route/rsm.inbox/.ring-state" 2>/dev/null)"
  [ "$(remote_hops "$ssh_log" ring)" = 1 ] || fail "the tick must ring through the remote inbox verb exactly once"
  assert_grep 'remote steer-inbox delivery attempt: rsm 001.msg result=rang' "$home/state/.watch-triage.log" \
    "the ring attempt must be recorded in the triage log"
  [ -s "$dir/herdr.log" ] || fail "the remote ring must reach the remote host's herdr"
  [ ! -s "$home/state/.wake-queue" ] || fail "a re-ring within budget queued a wake: $(cat "$home/state/.wake-queue")"

  # Within one grace of the last attempt the ladder stays quiet.
  touch -t 202001010000 "$rec"
  printf '001.msg\t1\t%s\n' "$(($(date +%s) - 120))" > "$rhome/state/parent-route/rsm.inbox/.ring-state"
  out=$(remote_inbox_tick_env "$fb" "$home" "$ssh_log" FM_TASK_INBOX_GRACE_SECS=3600 2>&1) \
    || fail "a quiet tick failed: $out"
  [ "$(remote_ring_count "$rhome")" = 1 ] || fail "a ring inside the grace spacing was not deferred"
  pass "watcher remote inbox: an unacknowledged remote record re-rings after grace without waking firstmate"
}

test_remote_inbox_ladder_quiet_after_acknowledgement() {
  local dir fb ssh_log home rhome rec out
  dir="$TMP_ROOT/remote-rering-ack"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-rering-ack)
  home=$(setup_remote_parent_home remote-rering-ack "$rhome")
  rec=$(fm_task_inbox_write_idempotent "$rhome/state/parent-route" rsm "please rename the metric") \
    || fail "could not seed the remote inbox record"
  touch -t 202001010000 "$rec"
  mv "$rec" "$rhome/state/parent-route/rsm.inbox/handled/"

  out=$(remote_inbox_tick_env "$fb" "$home" "$ssh_log" FM_FAKE_HERDR_LOG="$dir/herdr.log" 2>&1) \
    || fail "an acknowledged inbox tick failed: $out"
  [ "$(remote_hops "$ssh_log" due)" = 1 ] || fail "the tick must ask the remote host what is due"
  [ "$(remote_hops "$ssh_log" ring)" = 0 ] || fail "an acknowledged record was rung again"
  [ ! -s "$dir/herdr.log" ] || fail "an acknowledged record reached the remote pane: $(cat "$dir/herdr.log")"
  [ ! -e "$rhome/state/parent-route/rsm.inbox/.ring-state" ] || fail "an acknowledged record spent a ring attempt"
  [ ! -s "$home/state/.wake-queue" ] || fail "an acknowledged record queued a wake"

  # A remote copy that predates the inbox verb refuses the hop: the tick stays
  # quiet and the triage log names the remote's own refusal.
  out=$(remote_inbox_tick_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_RC=1 \
    FM_FAKE_SSH_STDERR="error: unknown command: inbox" 2>&1) \
    || fail "a refused remote hop must not fail the watcher: $out"
  assert_grep 'due check unreachable or failed (error: unknown command: inbox)' "$home/state/.watch-triage.log" \
    "a refused remote hop must leave the remote refusal in the triage log"
  [ ! -s "$home/state/.wake-queue" ] || fail "a refused remote hop queued a wake"
  pass "watcher remote inbox: an acknowledged remote record is never re-rung"
}

test_remote_inbox_idle_failure_still_spends_an_attempt_with_its_reason() {
  local dir fb ssh_log home rhome rec cs out
  dir="$TMP_ROOT/remote-idle-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-idle-fail)
  home=$(setup_remote_parent_home remote-idle-fail "$rhome")
  cs="$rhome/state/parent-route/rsm.inbox"
  rec=$(fm_task_inbox_write_idempotent "$rhome/state/parent-route" rsm "please rename the metric") \
    || fail "could not seed the remote inbox record"
  touch -t 202001010000 "$rec"

  out=$(remote_inbox_tick_env "$fb" "$home" "$ssh_log" FM_FAKE_HERDR_UNCONFIRMED=unknown FM_FAKE_HERDR_LOG="$dir/herdr.log" 2>&1) \
    || fail "an idle failed ring must not fail the watcher: $out"
  [ "$(remote_ring_count "$rhome")" = 1 ] || fail "an idle failed ring must still spend one attempt"
  assert_grep 'result=rang 4 reason=' "$home/state/.watch-triage.log" "the failed attempt must carry its reason in the triage log"
  assert_grep 'rc=4 token=' "$cs/001.ring-reason" "the failed attempt must record rc and token beside the record"
  pass "watcher remote inbox: an idle failed ring still spends an attempt and names its step"
}

test_remote_inbox_ladder_escalates_after_ring_max() {
  local dir fb ssh_log home rhome rec out rc wakes
  dir="$TMP_ROOT/remote-rering-max"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-rering-max)
  home=$(setup_remote_parent_home remote-rering-max "$rhome")
  rec=$(fm_task_inbox_write_idempotent "$rhome/state/parent-route" rsm "please rename the metric") \
    || fail "could not seed the remote inbox record"
  touch -t 202001010000 "$rec"

  remote_inbox_tick_env "$fb" "$home" "$ssh_log" FM_TASK_INBOX_RING_MAX=1 >/dev/null 2>&1 \
    || fail "the first in-budget ring failed"
  [ "$(remote_ring_count "$rhome")" = 1 ] || fail "the first tick must spend the only ring attempt"
  [ ! -s "$home/state/.wake-queue" ] || fail "an in-budget ring queued a wake"

  rc=0
  out=$(remote_inbox_tick_env "$fb" "$home" "$ssh_log" FM_TASK_INBOX_RING_MAX=1 2>&1) || rc=$?
  expect_code 0 "$rc" "the escalating tick must wake cleanly: $out"
  assert_contains "$out" "remote record 001.msg still unhandled after 1 doorbell delivery attempts" \
    "the spent ladder must wake firstmate naming the record and attempt count"
  assert_grep 'stale' "$home/state/.wake-queue" "the spent ladder must queue a stale wake"
  [ "$(cat "$rhome/state/parent-route/rsm.inbox/.escalated" 2>/dev/null)" = 001.msg ] \
    || fail "the remote escalation marker must name the escalated record"
  [ "$(remote_ring_count "$rhome")" = 1 ] || fail "escalation must not ring again"
  [ -f "$rec" ] || fail "escalation lost the remote record"
  wakes=$(wc -l < "$home/state/.wake-queue")

  out=$(remote_inbox_tick_env "$fb" "$home" "$ssh_log" FM_TASK_INBOX_RING_MAX=1 2>&1) \
    || fail "a tick after escalation failed: $out"
  [ "$(wc -l < "$home/state/.wake-queue")" = "$wakes" ] || fail "an escalated record queued a second wake"
  pass "watcher remote inbox: a spent ring budget queues exactly one stale wake"
}

# The watcher cycle runs the ladder detached: launching a pass against a slow
# host returns at once, and the pass's escalation is delivered by whichever
# watcher next finds its handoff, even after the launching watcher has exited.
test_remote_inbox_detached_pass_never_holds_the_cycle() {
  local dir fb ssh_log home rhome rec out rc i
  dir="$TMP_ROOT/remote-rering-detached"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-rering-detached)
  home=$(setup_remote_parent_home remote-rering-detached "$rhome")
  rec=$(fm_task_inbox_write_idempotent "$rhome/state/parent-route" rsm "please rename the metric") \
    || fail "could not seed the remote inbox record"
  touch -t 202001010000 "$rec"
  remote_inbox_tick_env "$fb" "$home" "$ssh_log" FM_TASK_INBOX_RING_MAX=1 >/dev/null 2>&1 \
    || fail "the first in-budget ring failed"

  rm -f "$home/state/.remote-inbox-tick"
  # shellcheck disable=SC2016 # expands in the child shell.
  out=$(remote_inbox_detached_env "$fb" "$home" "$ssh_log" \
    's=$(date +%s); remote_inbox_detached; echo "launch=$(( $(date +%s) - s ))"' \
    FM_TASK_INBOX_RING_MAX=1 FM_FAKE_SSH_DELAY=3 2>&1) \
    || fail "launching a detached pass failed: $out"
  case "$out" in
    *launch=0*|*launch=1*) ;;
    *) fail "a slow remote host held the watcher cycle: $out" ;;
  esac
  [ ! -s "$home/state/.remote-inbox-wake" ] || fail "the pass finished before the slow hop could have"
  i=0
  while [ ! -s "$home/state/.remote-inbox-wake" ] && [ "$i" -lt 200 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$home/state/.remote-inbox-wake" ] \
    || fail "the detached pass outlived its watcher without handing off its wake"
  [ "$(grep -c stale "$home/state/.wake-queue")" = 1 ] || fail "the detached pass must queue exactly one stale wake"

  rc=0
  out=$(remote_inbox_detached_env "$fb" "$home" "$ssh_log" \
    'remote_inbox_detached; echo unreached' FM_TASK_INBOX_GRACE_SECS=3600 2>&1) || rc=$?
  expect_code 0 "$rc" "delivering the handed-off wake must exit cleanly: $out"
  assert_contains "$out" "remote record 001.msg still unhandled after 1 doorbell delivery attempts" \
    "the next watcher must deliver the detached pass's wake"
  [ "${out#*unreached}" = "$out" ] || fail "the handed-off wake did not end the cycle: $out"
  [ ! -e "$home/state/.remote-inbox-wake" ] || fail "a delivered handoff must be consumed"
  pass "watcher remote inbox: a detached pass never holds the cycle and its wake is still delivered"
}

# A pass orphaned by a restarted watcher may still be mid-hop when the next
# watcher's tick comes due; the second pass must not ring or escalate the same
# record alongside it.
test_remote_inbox_pass_never_overlaps_an_inflight_pass() {
  local dir fb ssh_log home rhome rec out
  dir="$TMP_ROOT/remote-rering-overlap"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-rering-overlap)
  home=$(setup_remote_parent_home remote-rering-overlap "$rhome")
  rec=$(fm_task_inbox_write_idempotent "$rhome/state/parent-route" rsm "please rename the metric") \
    || fail "could not seed the remote inbox record"
  touch -t 202001010000 "$rec"

  rm -f "$home/state/.remote-inbox-tick"
  # shellcheck disable=SC2016 # expands in the child shell.
  out=$(remote_inbox_detached_env "$fb" "$home" "$ssh_log" \
    '( fm_lock_try_acquire "$STATE/.remote-inbox.lock" && touch "$STATE/held" && /bin/sleep 30 ) &
     holder=$!
     while [ ! -e "$STATE/held" ]; do sleep 0.1; done
     remote_inbox_tick; rc=$?
     kill "$holder"
     echo "rc=$rc"' \
    FM_TASK_INBOX_RING_MAX=1 2>&1) || fail "a tick beside an in-flight pass failed: $out"
  assert_contains "$out" "rc=0" "a tick beside an in-flight pass must return cleanly: $out"
  [ "$(remote_hops "$ssh_log" due)" = 0 ] || fail "a second pass reached the remote host beside an in-flight pass"
  [ "$(remote_ring_count "$rhome")" = 0 ] || fail "a second pass spent a ring attempt beside an in-flight pass"
  [ ! -s "$home/state/.wake-queue" ] || fail "a second pass queued a wake beside an in-flight pass"
  pass "watcher remote inbox: a pass never overlaps one still in flight"
}

test_remote_inbox_ladder_escalates_bookkeeping_failure() {
  local dir fb ssh_log home rhome rec out wakes
  dir="$TMP_ROOT/remote-rering-bookkeeping"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-rering-bookkeeping)
  home=$(setup_remote_parent_home remote-rering-bookkeeping "$rhome")
  rec=$(fm_task_inbox_write_idempotent "$rhome/state/parent-route" rsm "please rename the metric") \
    || fail "could not seed the remote inbox record"
  touch -t 202001010000 "$rec"
  mkdir "$rhome/state/parent-route/rsm.inbox/.ring-state"

  out=$(remote_inbox_tick_env "$fb" "$home" "$ssh_log" 2>&1) \
    || fail "a confirmed bookkeeping failure must wake cleanly: $out"
  assert_contains "$out" "remote steering-inbox ladder bookkeeping unwritable" \
    "a confirmed counter-write failure must surface as stale"
  assert_grep 'stale' "$home/state/.wake-queue" "bookkeeping failure must queue a stale wake"
  [ "$(remote_hops "$ssh_log" ring)" = 1 ] || fail "the failed bookkeeping must follow one ring attempt"
  [ -f "$rec" ] || fail "bookkeeping failure lost the unhandled record"
  [ "$(cat "$rhome/state/parent-route/rsm.inbox/.escalated" 2>/dev/null)" = 001.msg ] \
    || fail "the failed bookkeeping record must be marked escalated"
  wakes=$(wc -l < "$home/state/.wake-queue")
  out=$(remote_inbox_tick_env "$fb" "$home" "$ssh_log" 2>&1) \
    || fail "a tick after bookkeeping escalation failed: $out"
  [ "$(wc -l < "$home/state/.wake-queue")" = "$wakes" ] || fail "bookkeeping failure queued a second wake"
  [ "$(remote_hops "$ssh_log" ring)" = 1 ] || fail "bookkeeping failure retried after escalation"
  pass "watcher remote inbox: confirmed bookkeeping failure escalates once instead of retrying forever"
}

test_remote_inbox_marker_retry_preserves_wake_identity() {
  local mode dir fb ssh_log home rhome rec out wakes rows
  for mode in spent bookkeeping unavailable; do
    dir="$TMP_ROOT/remote-marker-retry-$mode"; mkdir -p "$dir"
    fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
    rhome=$(setup_remote_secondmate_home "remote-marker-retry-$mode")
    home=$(setup_remote_parent_home "remote-marker-retry-$mode" "$rhome")
    rec=$(fm_task_inbox_write_idempotent "$rhome/state/parent-route" rsm "please rename the metric") \
      || fail "could not seed the remote inbox record"
    touch -t 202001010000 "$rec"
    if [ "$mode" = spent ]; then
      printf '001.msg\t3\t0\n' > "$rhome/state/parent-route/rsm.inbox/.ring-state"
    elif [ "$mode" = bookkeeping ]; then
      mkdir "$rhome/state/parent-route/rsm.inbox/.ring-state"
    else
      cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"error":{"code":"pane_not_found"}}'
exit 1
SH
    fi

    out=$(remote_inbox_tick_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_FAIL_INBOX_MARKER=1 2>&1) \
      || fail "$mode escalation with lost marker failed: $out"
    assert_contains "$out" 'stale:' "$mode escalation must wake on the first notification"
    [ ! -e "$rhome/state/parent-route/rsm.inbox/.escalated" ] || fail "the failed marker hop executed remotely"
    wakes=$(wc -l < "$home/state/.wake-queue")
    [ "$wakes" -eq 1 ] || fail "$mode escalation must queue exactly one wake"
    assert_grep 'escalation marker for 001.msg was not written' "$home/state/.watch-triage.log" \
      "marker transport failure must remain visible in triage"

    out=$(remote_inbox_tick_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_FAIL_INBOX_MARKER=1 2>&1) \
      || fail "$mode repeated marker loss failed: $out"
    [ -z "$out" ] || fail "$mode retry emitted a second wake: $out"
    [ "$(wc -l < "$home/state/.wake-queue")" = "$wakes" ] || fail "$mode retry appended a second wake"

    out=$(remote_inbox_tick_env "$fb" "$home" "$ssh_log" 2>&1) \
      || fail "$mode marker recovery failed: $out"
    [ -z "$out" ] || fail "$mode marker recovery emitted a second wake: $out"
    [ "$(cat "$rhome/state/parent-route/rsm.inbox/.escalated" 2>/dev/null)" = 001.msg ] \
      || fail "$mode marker must be retried even when the wake is already queued"
    [ "$(remote_hops "$ssh_log" escalated)" = 3 ] || fail "$mode must retry each failed marker hop"
    rows=$(drain_out "$home")
    [ "$(printf '%s\n' "$rows" | awk -F '\t' '$3 == "stale" {n++} END {print n+0}')" = 1 ] \
      || fail "$mode marker retries must deliver one stale row to the queue consumer"

    mv "$rec" "$rhome/state/parent-route/rsm.inbox/handled/"
    rec=$(fm_task_inbox_write_idempotent "$rhome/state/parent-route" rsm "please rename the second metric") \
      || fail "could not seed the next inbox record"
    touch -t 202001010000 "$rec"
    out=$(remote_inbox_tick_env "$fb" "$home" "$ssh_log" FM_TASK_INBOX_RING_MAX=0 2>&1) \
      || fail "$mode next-record escalation failed: $out"
    assert_contains "$out" 'remote record 002.msg' "a different record must get its own wake"
    [ "$(wc -l < "$home/state/.wake-queue")" -eq 2 ] || fail "the first record's queued wake suppressed the next record"
  done
  pass "watcher remote inbox: marker retries preserve one notification per record"
}

test_remote_enqueue_dedup_compares_same_size_records() {
  local state a b c d e f
  state="$TMP_ROOT/dedup-size/state"; mkdir -p "$state"
  a=$(fm_task_inbox_write_idempotent "$state" rsm $'multi-byte h\xc3\xa9llo\nsecond line') || fail "first enqueue failed"
  b=$(fm_task_inbox_write_idempotent "$state" rsm $'multi-byte h\xc3\xa9llo\nsecond line') || fail "repeat enqueue failed"
  [ "$a" = "$b" ] || fail "an identical body must land on the same record, got $a and $b"
  c=$(fm_task_inbox_write_idempotent "$state" rsm $'multi-byte h\xc3\xa9llo\nsecond lime') || fail "same-size enqueue failed"
  [ "$c" != "$a" ] || fail "a same-size distinct body must get its own record"
  d=$(fm_task_inbox_write_idempotent "$state" rsm $'multi-byte h\xc3\xa9llo\nsecond line' fire-and-forget) \
    || fail "fire-and-forget enqueue failed"
  [ "$d" != "$a" ] || fail "a fire-and-forget record must not dedup onto an ordinary one"
  e=$(fm_task_inbox_write_idempotent "$state" rsm $'multi-byte h\xc3\xa9llo\nsecond line' fire-and-forget) \
    || fail "repeat fire-and-forget enqueue failed"
  [ "$e" = "$d" ] || fail "an identical fire-and-forget body must land on the same record"
  mv "$a" "$state/rsm.inbox/handled/"
  f=$(fm_task_inbox_write_idempotent "$state" rsm $'multi-byte h\xc3\xa9llo\nsecond line') || fail "post-ack enqueue failed"
  [ "$f" = "$state/rsm.inbox/handled/${a##*/}" ] || fail "an acknowledged identical record must be found in handled/, got $f"
  pass "remote enqueue dedup: only same-size records are compared and exact matches still dedup"
}

test_remote_one_way_request_identity() {
  local dir fb ssh_log rhome home count id id2 retry_id
  dir="$TMP_ROOT/remote-oneway"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-oneway)
  home=$(setup_remote_parent_home remote-oneway "$rhome")
  send_env "$fb" "$home" "$ssh_log" "$SEND" rsm --one-way 'continue supervision' >"$dir/out" 2>"$dir/err" || fail "first one-way send failed"
  id=$(fm_task_inbox_request_id "$rhome/state/parent-route/rsm.inbox/001.msg")
  fm_task_inbox_request_id_valid "$id" || fail "one-way request has no durable identity"
  send_env "$fb" "$home" "$ssh_log" "$SEND" rsm --one-way 'continue supervision' >"$dir/out" 2>"$dir/err" || fail "second outstanding one-way send failed"
  id2=$(fm_task_inbox_request_id "$rhome/state/parent-route/rsm.inbox/002.msg")
  [ "$id" != "$id2" ] || fail "distinct requests shared their identity"
  mv "$rhome/state/parent-route/rsm.inbox/001.msg" "$rhome/state/parent-route/rsm.inbox/handled/"
  send_env "$fb" "$home" "$ssh_log" "$SEND" rsm --one-way 'continue supervision' >"$dir/out" 2>"$dir/err" || fail "repeat after handling failed"
  [ -f "$rhome/state/parent-route/rsm.inbox/003.msg" ] || fail "a handled request swallowed a distinct send"
  send_env "$fb" "$home" "$ssh_log" "FM_SEND_REQUEST_ID=$id" "$SEND" rsm --one-way 'continue supervision' >"$dir/out" 2>"$dir/err" || fail "handled request retry failed"
  [ ! -f "$rhome/state/parent-route/rsm.inbox/004.msg" ] || fail "handled retry duplicated its request"
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_AMBIGUOUS=1 "$SEND" rsm --one-way 'ambiguous request' >"$dir/out" 2>"$dir/err" && fail "lost transport claimed success"
  [ -f "$rhome/state/parent-route/rsm.inbox/004.msg" ] && [ ! -f "$rhome/state/parent-route/rsm.inbox/005.msg" ] || fail "transport retry did not deduplicate"
  assert_contains "$(cat "$dir/err")" 'FM_SEND_REQUEST_ID=' "ambiguous send must preserve the request id"
  assert_not_contains "$(cat "$dir/err")" 'FM_PENDING_REPLY_EXISTING_CORR=' "one-way retry must not advertise an empty correlation"
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_HANG=60 FM_SEND_REMOTE_BUDGET=1 "$SEND" rsm --one-way 'timed request' >"$dir/out" 2>"$dir/err" && fail "timed-out transport claimed success"
  retry_id=$(sed -n 's/.*FM_SEND_REQUEST_ID=\([0-9a-f]*\).*/\1/p' "$dir/err")
  fm_task_inbox_request_id_valid "$retry_id" || fail "timeout guidance lost its durable request id"
  assert_not_contains "$(cat "$dir/err")" 'FM_PENDING_REPLY_EXISTING_CORR=' "timeout must not advertise an empty correlation"
  send_env "$fb" "$home" "$ssh_log" "FM_SEND_REQUEST_ID=$retry_id" "$SEND" rsm --one-way 'timed request' >"$dir/out" 2>"$dir/err" || fail "timeout-guided retry failed"
  [ "$(fm_task_inbox_request_id "$rhome/state/parent-route/rsm.inbox/005.msg")" = "$retry_id" ] || fail "timeout retry used a different request identity"
  [ -z "$(pending_record "$home")" ] || fail "one-way requests created reply debt"
  count=$(remote_inbox_records "$rhome" | wc -l | tr -d ' ')
  [ "$count" = 4 ] || fail "unexpected one-way request count: $count"
  pass "remote one-way requests distinguish repetition from handled, outstanding, and transport retries"
}

test_remote_probe_follows_acknowledgement() {
  local dir fb rhome rec corr=0123456789abcdef out real_grep
  dir="$TMP_ROOT/remote-probe-ack"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  rhome=$(setup_remote_secondmate_home remote-probe-ack)
  rec=$(fm_task_inbox_write_idempotent "$rhome/state/parent-route" rsm "corr=$corr report the build") \
    || fail "could not seed the probe record"
  real_grep=$(command -v grep)
  cat > "$fb/grep" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$FM_PROBE_RECORD" ] && [ -f "$FM_PROBE_RECORD" ]; then
    mv "$FM_PROBE_RECORD" "${FM_PROBE_RECORD%/*}/handled/${FM_PROBE_RECORD##*/}" || exit 2
    break
  fi
done
exec "$FM_REAL_GREP" "$@"
SH
  chmod +x "$fb/grep"
  out=$(FM_HOME="$rhome" PATH="$fb:$PATH" FM_REAL_GREP="$real_grep" FM_PROBE_RECORD="$rec" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" probe rsm "$corr") || fail "probe failed during acknowledgement"
  [ ! -e "$rec" ] && [ -f "${rec%/*}/handled/${rec##*/}" ] || fail "acknowledgement race was not exercised"
  [ "$out" = landed ] || fail "acknowledgement during probe hid a delivered message: $out"
  out=$(FM_HOME="$rhome" "$ROOT/bin/fm-remote-secondmate-control.sh" probe rsm "$corr")
  [ "$out" = landed ] || fail "handled message was not found"
  out=$(FM_HOME="$rhome" "$ROOT/bin/fm-remote-secondmate-control.sh" probe rsm fedcba9876543210)
  [ "$out" = absent ] || fail "missing correlation was reported as delivered"
  pass "remote probe follows an acknowledgement into handled storage"
}

test_remote_pending_probe_never_holds_the_cycle() {
  local dir fb ssh_log home rhome landed lost out
  dir="$TMP_ROOT/remote-pending-detached"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-pending-detached)
  home=$(setup_remote_parent_home remote-pending-detached "$rhome")
  landed=$(FM_PENDING_REPLY_GRACE_SECS=0 fm_pending_reply_create "$home" "$home/state" rsm 'report the first build')
  lost=$(FM_PENDING_REPLY_GRACE_SECS=0 fm_pending_reply_create "$home" "$home/state" rsm 'report the second build')
  fm_pending_reply_mark_delivery_unknown "$home/state" "$landed"
  fm_pending_reply_prepare_delivery "$home/state" "$lost"
  cat > "$dir/probe" <<'SH'
#!/usr/bin/env bash
: > "$FM_PROBE_DIR/started"
while [ ! -e "$FM_PROBE_DIR/release" ]; do /bin/sleep 0.05; done
if [ "$2" = "$FM_LANDED_CORR" ]; then printf 'landed\n'; else printf 'absent\n'; fi
SH
  chmod +x "$dir/probe"
  out=$(remote_inbox_detached_env "$fb" "$home" "$ssh_log" '
    ( /bin/sleep 10; touch "$FM_PROBE_DIR/release" ) </dev/null >/dev/null 2>&1 &
    watchdog=$!
    trap '\''touch "$FM_PROBE_DIR/release"; kill "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true'\'' EXIT
    remote_inbox_detached
    fm_pending_reply_tick "$STATE"
    for ((i = 0; i < 100; i++)); do
      [ ! -e "$FM_PROBE_DIR/started" ] || break
      /bin/sleep 0.05
    done
    [ -e "$FM_PROBE_DIR/started" ] || { echo "detached probe never started"; exit 1; }
    fm_pending_reply_tick "$STATE"
    [ ! -e "$FM_PROBE_DIR/release" ] || { echo "probe or its lock held the cycle"; exit 1; }
    touch "$FM_PROBE_DIR/release"
    wait "$REMOTE_INBOX_PID" || exit 1
    echo responsive
  ' FM_PENDING_REPLY_REMOTE_PROBE_HOOK="$dir/probe" FM_PROBE_DIR="$dir" FM_LANDED_CORR="$landed" \
    2>&1) || fail "remote pending probe stalled supervision: $out"
  [ "$out" = responsive ] || fail "unexpected detached probe result: $out"
  [ "$(fm_pending_reply_get "$(fm_pending_reply_path "$home/state" "$landed")" phase)" = awaiting_report ] \
    || fail "landed steer was not reconciled by the detached pass"
  [ "$(fm_pending_reply_get "$(fm_pending_reply_path "$home/state" "$lost")" phase)" = escalated ] \
    || fail "missing steer was not reconciled and escalated by the detached pass"
  pass "remote pending probes and their correlation locks never hold the watcher cycle"
}

test_remote_probe_follows_acknowledgement
test_remote_pending_probe_never_holds_the_cycle
test_remote_steer_lands_in_remote_inbox
test_remote_unreadable_ring_preserves_durable_enqueue
test_remote_rerun_is_idempotent
test_remote_retry_failure_preserves_ambiguous_expectation
test_remote_fire_and_forget_never_arms_reply_recovery
test_remote_send_revalidates_after_retirement_lock
test_remote_send_revalidates_parent_route_after_retirement_lock
test_remote_expected_host_revalidates_final_route
test_remote_resolve_key_closes_at_enqueue
test_remote_slash_rides_inbox
test_remote_real_failure_still_fails
test_remote_exit3_no_longer_delivered
test_remote_transport_loss_preserves_expectation
test_remote_send_budget_bounds_busy_lane
test_local_pending_reports_delivered_unconfirmed
test_local_pending_does_not_close_resolve_key
test_local_secondmate_pending_keeps_expectation_armed
test_remote_inbox_ladder_rerings_unacknowledged_record
test_remote_inbox_ladder_quiet_after_acknowledgement
test_remote_inbox_idle_failure_still_spends_an_attempt_with_its_reason
test_remote_inbox_ladder_escalates_after_ring_max
test_remote_inbox_detached_pass_never_holds_the_cycle
test_remote_inbox_pass_never_overlaps_an_inflight_pass
test_remote_inbox_ladder_escalates_bookkeeping_failure
test_remote_inbox_marker_retry_preserves_wake_identity
test_remote_enqueue_dedup_compares_same_size_records
test_remote_one_way_request_identity

echo "all fm-send-remote-delivery tests passed"
