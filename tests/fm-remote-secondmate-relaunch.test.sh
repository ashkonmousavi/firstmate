#!/usr/bin/env bash
# tests/fm-remote-secondmate-relaunch.test.sh - regression coverage for
# bin/fm-remote-secondmate-relaunch.sh: the parent-side tool an operator runs
# to move a remote secondmate onto a new harness, model, or effort.
#
# Reproduces the observed defect: running
# bin/fm-on.sh <id> fm-remote-secondmate-control.sh relaunch <id> <harness>
# <model> <effort> relaunches the agent on its host, but that host-local verb
# can only rewrite its own endpoint record. The parent's own state/<id>.meta
# kept naming the runtime the mate used to run. The wrapper drives the same
# host-local relaunch and then republishes this home's own record from the
# identity the host confirmed.
#
# The remote transport is faked at the SSH boundary, exactly as the other
# remote-secondmate suites fake it, rather than exercising a real host.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# These fake homes have no supervisor lease; never inherit the invoking harness.
export FM_TEST_SEAM=1 FM_TEST_HARNESS=unknown
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }

TMP=$(fm_test_tmproot fm-remote-secondmate-relaunch)
HOME_DIR="$TMP/home"
FAKEBIN=$(fm_fakebin "$TMP/fake")
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"

printf -- '- ios - iOS delivery (host: remote-mac; root: /srv/fm; home: /srv/fm-home; scope: iOS; projects: alpha; added 2026-08-01)\n' \
  > "$HOME_DIR/data/secondmates.md"

reset_meta() {
  fm_write_meta "$HOME_DIR/state/ios.meta" \
    "window=remote:ios" \
    "endpoint_task_id=ios" \
    "worktree=/srv/fm-home" \
    "project=/srv/fm" \
    "harness=pi" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "model=openai-codex/gpt-5.6-sol" \
    "effort=medium" \
    "home=/srv/fm-home" \
    "projects=alpha" \
    "remote_host=remote-mac" \
    "remote_root=/srv/fm" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
}

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
argv_b64=$4
command_fields=$(perl -MMIME::Base64=decode_base64 -e '
  my $data=decode_base64($ARGV[0]);
  my @args=split(/\0/, $data);
  print join("\t", map { defined $_ ? $_ : "" } @args[0..7]);
' "$argv_b64")
IFS=$'\t' read -r cmd action id harness model effort quota_flag quota_reason <<EOF
$command_fields
EOF
[ "$cmd" = fm-remote-secondmate-control.sh ] || exit 93
[ "$action" = relaunch ] || exit 94
case "$FM_FAKE_RELAUNCH_MODE" in
  capacity) printf 'deferred: replacement capacity unavailable\n' >&2; exit 75 ;;
  busy) printf 'busy: background shell running\n'; exit 75 ;;
  unknown) exit 255 ;;
  unconfirmed) printf 'relaunched without route confirmation\n'; exit 0 ;;
  quota)
    [ "$quota_flag" = --quota-override ] && [ -n "$quota_reason" ] || { echo 'error: exhausted_now' >&2; exit 1; }
    printf 'notice: fm-control quota check refuses grok; proceeding under --quota-override: %s\n' "$quota_reason" >&2
    ;;
  notice)
    printf 'notice: fm-control launches grok without the quota check: unavailable fixture\n' >&2
    ;;
  refuse)
    printf 'error: unverified remote secondmate harness: %s\n' "$harness" >&2
    exit 1
    ;;
  confirm-other)
    harness=claude
    model=claude-opus-5-5
    effort=medium
    ;;
esac
printf 'relaunched %s harness=%s from=pi model=%s effort=%s backend=herdr endpoint=fm-remote:w1:p1 worktree=/srv/fm-home\n' \
  "$id" "$harness" "$model" "$effort"
printf 'schema=fm-remote-secondmate-control.v1\n'
printf 'backend=herdr\n'
printf 'target=fm-remote:w1:p1\n'
printf 'herdr_session=fm-remote\n'
printf 'harness=%s\n' "$harness"
printf 'model=%s\n' "$model"
printf 'effort=%s\n' "$effort"
if [ "$FM_FAKE_RELAUNCH_MODE" = quota ]; then
  printf 'quota_override=%s\nquota_override_evidence=refuse: exhausted_now; best alternative: codex\n' "$quota_reason"
fi
SH
chmod +x "$FAKEBIN/fake-ssh"

run_relaunch() {  # <args...>
  env FM_HOME="$HOME_DIR" FM_SSH_BIN="$FAKEBIN/fake-ssh" \
    FM_FAKE_RELAUNCH_MODE="${FM_FAKE_RELAUNCH_MODE:-}" \
    "$ROOT/bin/fm-remote-secondmate-relaunch.sh" "$@" 2>&1
}

# A retryable host refusal must survive the transport without republishing.
reset_meta
cp "$HOME_DIR/state/ios.meta" "$TMP/ios-before-busy.meta"
FM_FAKE_RELAUNCH_MODE=busy
OUT=$(run_relaunch ios claude default default); RC=$?
unset FM_FAKE_RELAUNCH_MODE
expect_code 75 "$RC" "a busy background shell remains retryable through the parent wrapper"$'\n'"$OUT"
assert_contains "$OUT" 'busy: background shell running' 'the busy reason reaches the caller'
cmp -s "$TMP/ios-before-busy.meta" "$HOME_DIR/state/ios.meta" || fail 'busy remote relaunch changed parent metadata'
pass 'busy remote relaunch returns 75 and preserves parent metadata'

# --- a successful relaunch republishes the parent's own route record --------
reset_meta
RECOVERY_NOW=$(date +%s)
printf '%s\tattempt\n%s\tattempt\n%s\tattempt\n' "$RECOVERY_NOW" "$RECOVERY_NOW" "$RECOVERY_NOW" \
  > "$HOME_DIR/state/.secondmate-relaunch-ios"
printf '%s\tdead\n' "$RECOVERY_NOW" > "$HOME_DIR/state/.secondmate-relaunch-bound-ios"
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 0 "$RC" "a confirmed remote relaunch should succeed"$'\n'"$OUT"
assert_absent "$HOME_DIR/state/.secondmate-relaunch-bound-ios" "confirmed parent-side relaunch kept the park record"
ATTEMPTS=$(STATE="$HOME_DIR/state" bash -c '. "$1"; fm_secondmate_liveness_recent_attempts ios 3600' _ \
  "$ROOT/bin/fm-secondmate-liveness-lib.sh")
[ "$ATTEMPTS" = 0 ] || fail "confirmed parent-side relaunch did not restore the recovery budget"
[ "$(awk -F '\t' '$2 == "rearmed" { n++ } END { print n + 0 }' "$HOME_DIR/state/.secondmate-relaunch-ios")" = 1 ] \
  || fail "parent-side relaunch must record exactly one rearm"
assert_contains "$OUT" "relaunched ios harness=claude" \
  "the wrapper should still print the host's own confirmation line"
assert_grep 'harness=claude' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed harness"
assert_grep 'model=claude-opus-5-5' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed model"
assert_grep 'effort=medium' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed effort"
assert_no_grep 'harness=pi' "$HOME_DIR/state/ios.meta" \
  "the stale runtime should not still be recorded"
assert_no_grep 'model=openai-codex/gpt-5.6-sol' "$HOME_DIR/state/ios.meta" \
  "the stale model should not still be recorded"
assert_grep 'remote_host=remote-mac' "$HOME_DIR/state/ios.meta" \
  "unrelated route fields must survive the update"
assert_grep 'window=remote:ios' "$HOME_DIR/state/ios.meta" \
  "unrelated identity fields must survive the update"
pass "a successful remote relaunch republishes the parent's harness, model, and effort"

# --- the parent records what the host confirmed, not what it was asked ------
reset_meta
printf '%s\tattempt\n' "$(date +%s)" >> "$HOME_DIR/state/.secondmate-relaunch-ios"
FM_FAKE_RELAUNCH_MODE=confirm-other
OUT=$(run_relaunch ios default default default); RC=$?
unset FM_FAKE_RELAUNCH_MODE
expect_code 0 "$RC" "a relaunch whose host resolves a different identity should succeed"$'\n'"$OUT"
assert_grep 'harness=claude' "$HOME_DIR/state/ios.meta" \
  "the parent record should follow the host's confirmed harness"
assert_grep 'model=claude-opus-5-5' "$HOME_DIR/state/ios.meta" \
  "the parent record should follow the host's confirmed model"
assert_no_grep 'harness=default' "$HOME_DIR/state/ios.meta" \
  "the parent record must not keep the unresolved request"
ATTEMPTS=$(STATE="$HOME_DIR/state" bash -c '. "$1"; fm_secondmate_liveness_recent_attempts ios 3600' _ \
  "$ROOT/bin/fm-secondmate-liveness-lib.sh")
[ "$ATTEMPTS" = 1 ] || fail "an ordinary remote relaunch reset its attempt budget without a park record"
pass "a remote relaunch records the identity the host confirmed"

# --- a refused relaunch leaves the parent's record untouched -----------------
reset_meta
cp "$HOME_DIR/state/ios.meta" "$TMP/ios-before-refusal.meta"
FM_FAKE_RELAUNCH_MODE=refuse
OUT=$(run_relaunch ios notaharness - -); RC=$?
unset FM_FAKE_RELAUNCH_MODE
[ "$RC" -ne 0 ] || fail "a refused host relaunch must not be reported as successful"
assert_contains "$OUT" "unverified remote secondmate harness" \
  "the refusal reason should reach the caller"
cmp -s "$TMP/ios-before-refusal.meta" "$HOME_DIR/state/ios.meta" \
  || fail "a refused relaunch must not touch the parent's record"
pass "a refused remote relaunch leaves the parent's record untouched"

for FAILURE_MODE in refuse capacity unknown unconfirmed; do
  printf '%s\tdead\n' "$(date +%s)" > "$HOME_DIR/state/.secondmate-relaunch-bound-ios"
  cp "$HOME_DIR/state/.secondmate-relaunch-ios" "$TMP/ledger-before-failure"
  OUT=$(FM_FAKE_RELAUNCH_MODE="$FAILURE_MODE" run_relaunch ios claude - -); RC=$?
  [ "$RC" -ne 0 ] || fail "$FAILURE_MODE relaunch should fail"
  [ "$FAILURE_MODE" != capacity ] || expect_code 75 "$RC" "remote capacity refusal must remain retryable"
  cmp -s "$TMP/ios-before-refusal.meta" "$HOME_DIR/state/ios.meta" \
    || fail "$FAILURE_MODE refusal changed the parent record"
  assert_absent "$HOME_DIR/state/.remote-inherit-ios.lock" "$FAILURE_MODE relaunch stranded the transaction lock"
  assert_present "$HOME_DIR/state/.secondmate-relaunch-bound-ios" "$FAILURE_MODE relaunch cleared the parent's park record"
  cmp -s "$HOME_DIR/state/.secondmate-relaunch-ios" "$TMP/ledger-before-failure" \
    || fail "$FAILURE_MODE relaunch changed the recovery budget"
done
pass "refused, unknown, and unconfirmed remote relaunches preserve parked recovery state"

# --- a local (non-remote) secondmate is refused, not silently mishandled ----
fm_write_meta "$HOME_DIR/state/local1.meta" \
  "window=firstmate:fm-local1" "endpoint_task_id=local1" \
  "worktree=/srv/local1" "project=/srv/local1" "harness=codex" \
  "kind=secondmate" "mode=secondmate" "yolo=off" "home=/srv/local1"
OUT=$(run_relaunch local1 claude - -); RC=$?
[ "$RC" -ne 0 ] || fail "a local secondmate must not be accepted by the remote relaunch tool"
assert_contains "$OUT" "not a remotely placed secondmate" \
  "the refusal should explain the tool this task needs instead"
pass "a local secondmate is refused by the remote relaunch tool"

# --- a relaunch keeps an already-armed PR poll authenticating ---------------
# fm-pr-check.sh now refuses to arm a poll on a kind=secondmate record, but a
# record armed before that refusal can still carry the block until the
# watcher retires it. fm-pr-check.sh wrote pr= (and, when a forge head was
# readable, pr_head=) as the LAST lines of the record, and
# fm_pr_metadata_identity_parse treats any other key appearing after pr= as
# invalid, so this wrapper must not append its harness=/model=/effort= lines
# after that identity block. The fixture is seeded the way such a record was
# really written: pr= appended last to the meta, then the poll artifacts
# published through the same fm_pr_poll_prepare/fm_pr_poll_publish_prepared
# pair fm-pr-check.sh uses, since the refused entry point cannot arm it.
reset_meta
printf 'pr=https://github.com/example/repo/pull/1\n' >> "$HOME_DIR/state/ios.meta" \
  || fail "could not write the pr= identity for the relaunch-ordering test"
fm_pr_poll_prepare "$HOME_DIR/state" ios github \
  https://github.com/example/repo/pull/1 github.com example/repo 1 \
  "$ROOT/bin/fm-pr-poll.sh" \
  || fail "could not prepare the PR poll fixture for the relaunch-ordering test"
fm_pr_poll_publish_prepared \
  || fail "could not publish the PR poll fixture for the relaunch-ordering test"
fm_pr_poll_artifacts_valid "$HOME_DIR/state" ios "$ROOT/bin/fm-pr-poll.sh" \
  || fail "PR poll fixture did not authenticate before the relaunch"
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 0 "$RC" "a confirmed remote relaunch should succeed with an armed PR poll"$'\n'"$OUT"
fm_pr_poll_artifacts_valid "$HOME_DIR/state" ios "$ROOT/bin/fm-pr-poll.sh" \
  || fail "a remote relaunch broke PR poll authentication by writing harness/model/effort after pr="
pass "a remote relaunch keeps an already-armed PR poll authenticating"

reset_meta
cp "$HOME_DIR/state/ios.meta" "$TMP/before-quota.meta"
OUT=$(FM_FAKE_RELAUNCH_MODE=quota run_relaunch ios grok - -); RC=$?
expect_code 1 "$RC" "remote relaunch must preserve a host quota refusal"
cmp -s "$HOME_DIR/state/ios.meta" "$TMP/before-quota.meta" || fail "refusal changed parent metadata"
OUT=$(FM_FAKE_RELAUNCH_MODE=quota run_relaunch ios grok - - --quota-override 'review override'); RC=$?
expect_code 0 "$RC" "remote relaunch must forward the explicit override"$'\n'"$OUT"
[ "$(printf '%s\n' "$OUT" | grep -c '^notice: fm-control quota check refuses grok')" = 1 ] || fail "remote relaunch lost or duplicated override diagnostics: $OUT"
grep -Fxq 'quota_override=review override' "$HOME_DIR/state/ios.meta" || fail "parent lost confirmed override"
grep -Fxq 'quota_override_evidence=refuse: exhausted_now; best alternative: codex' "$HOME_DIR/state/ios.meta" || fail "parent lost confirmed evidence"
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 0 "$RC" "later relaunch should succeed"
assert_no_grep 'quota_override' "$HOME_DIR/state/ios.meta" "later relaunch inherited stale override evidence"
pass "remote relaunch forwards explicit quota overrides and mirrors confirmed evidence"

reset_meta
cp "$HOME_DIR/state/ios.meta" "$TMP/before-stream-refusal.meta"
env FM_HOME="$HOME_DIR" FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_RELAUNCH_MODE=quota \
  "$ROOT/bin/fm-remote-secondmate-relaunch.sh" ios grok - - > "$TMP/refusal.out" 2> "$TMP/refusal.err"; RC=$?
expect_code 1 "$RC" "remote relaunch refusal must preserve its stderr"
assert_grep 'error: exhausted_now' "$TMP/refusal.err" "remote relaunch lost refusal stderr"
assert_no_grep 'error:' "$TMP/refusal.out" "remote relaunch moved refusal diagnostics into stdout"
cmp -s "$HOME_DIR/state/ios.meta" "$TMP/before-stream-refusal.meta" || fail "remote stderr refusal changed metadata"
env FM_HOME="$HOME_DIR" FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_RELAUNCH_MODE=notice \
  "$ROOT/bin/fm-remote-secondmate-relaunch.sh" ios grok - - > "$TMP/notice.out" 2> "$TMP/notice.err"; RC=$?
expect_code 0 "$RC" "uncertain remote relaunch must preserve its notice"
[ "$(grep -c '^notice: fm-control launches grok without the quota check:' "$TMP/notice.err")" = 1 ] || fail "remote relaunch lost or duplicated uncertainty stderr"
assert_no_grep 'notice:' "$TMP/notice.out" "remote relaunch moved quota notices into stdout"
assert_grep 'harness=grok' "$HOME_DIR/state/ios.meta" "notice prevented remote route confirmation"
pass "remote relaunch wrapper preserves host quota notices and refusal stderr"

echo "ALL TESTS PASSED"
