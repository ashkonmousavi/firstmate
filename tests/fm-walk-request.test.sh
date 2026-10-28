#!/usr/bin/env bash
# tests/fm-walk-request.test.sh - behavior tests for the walk-request carrier:
# the mate-side typed request on the parent channel (bin/fm-walk-request.sh)
# and the MAIN-side standing check that dispatches it through the home-private
# walker dispatcher and returns the outcome to the mate
# (bin/fm-walk-request-check.sh).
#
# The dispatcher and fm-send are fakes that record their arguments; the mate
# channel is the real parent-channel library writing into a scratch parent
# home. No bridge, no sign-in, no network, no real tmux.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-walk-request)
CARRIER="$ROOT/bin/fm-walk-request.sh"
CHECK="$ROOT/bin/fm-walk-request-check.sh"
RELEASE=0123456789abcdef0123456789abcdef01234567

# make_mate <name>: a local-route secondmate home reporting into <parent>.
make_mate() {  # <name> <parent-home>
  local mate="$TMP_ROOT/$1" parent=$2
  mkdir -p "$mate/state" "$parent/state"
  printf '%s\n' "$1" > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  printf 'kind=secondmate\n' > "$parent/state/$1.meta"
  printf '%s\n' "$mate"
}

make_parent() {  # <name>
  local parent="$TMP_ROOT/$1"
  mkdir -p "$parent/state"
  printf '%s\n' "$parent"
}

run_carrier() {  # <mate-home> <args...>
  local mate=$1
  shift
  FM_HOME="$mate" FM_STATE_OVERRIDE="$mate/state" "$CARRIER" "$@"
}

run_check() {  # <parent-home> [env assignments...]
  local parent=$1
  shift
  env "$@" FM_HOME="$parent" FM_STATE_OVERRIDE="$parent/state" \
    "$CHECK" check
}

# fake_dispatcher <path>: records one argument line per invocation, emits a
# reply, and exits 0 - the shape the real dispatcher shows on a successful
# walk (reply text then exit 0; the "unverified" marker line is not load
# bearing here).
fake_dispatcher() {
  cat > "$1" <<SH
#!/usr/bin/env bash
printf 'args=%s\n' "\$*" >> '$1.calls'
sleep 0.2
echo 'walk green: every step passed at 1440 light and dark'
exit 0
SH
  chmod +x "$1"
}

# fake_send <path>: records its arguments and succeeds, the fire-and-forget
# contract the check relies on.
fake_send() {
  cat > "$1" <<SH
#!/usr/bin/env bash
printf 'target=%s id=%s text=%s\n' "\$1" "\$3" "\$4" >> '$1.calls'
exit 0
SH
  chmod +x "$1"
}

# wait_for <file> <needle>: bounded wait until <needle> appears in <file>.
wait_for() {
  local file=$1 needle=$2 n=0
  until grep -F -- "$needle" "$file" >/dev/null 2>&1; do
    n=$((n + 1))
    [ "$n" -le 100 ] || return 1
    sleep 0.1
  done
}

# --- the mate-side carrier ---------------------------------------------------

test_carrier_writes_the_typed_request() {
  local parent mate out
  parent=$(make_parent carrier-main)
  mate=$(make_mate carrier-mate "$parent")
  out=$(run_carrier "$mate" --brief /srv/walks/brief.md --release "$RELEASE" \
    --walks desk-step,money-step --bot J01Walker) \
    || fail "the carrier must succeed on a secondmate home"
  assert_contains "$out" "corr=" "the carrier prints its correlation id"
  assert_contains "$out" "once-key=desk-step@$RELEASE" "the carrier prints the first once-key"
  assert_contains "$out" "once-key=money-step@$RELEASE" "the carrier prints the second once-key"
  assert_grep 'walk-request: walks=desk-step,money-step brief=/srv/walks/brief.md' \
    "$parent/state/carrier-mate.status" "the typed line lands on the parent channel"
  assert_grep "release=$RELEASE" "$parent/state/carrier-mate.status" \
    "the typed line names the release"
  grep -qE 'corr=[0-9a-f]{16}' "$parent/state/carrier-mate.status" \
    || fail "the typed line carries a privacy-safe corr token"
  assert_grep 'bot=J01Walker' "$parent/state/carrier-mate.status" \
    "the typed line carries the bot name"
  pass "walk-request: the carrier writes one typed request on the parent channel"
}

test_carrier_refusals() {
  local parent mate rc
  parent=$(make_parent refusals-main)
  mate=$(make_mate refusals-mate "$parent")
  # A main home is not a secondmate: refused plainly.
  rc=0
  run_carrier "$parent" --brief /b.md --release "$RELEASE" --walks w1 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "the carrier must refuse a main home"
  # Invalid fields are refused before anything is written.
  rc=0
  run_carrier "$mate" --brief relative.md --release "$RELEASE" --walks w1 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a relative brief path must be refused"
  rc=0
  run_carrier "$mate" --brief /b.md --release nothex --walks w1 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a non-hex release must be refused"
  rc=0
  run_carrier "$mate" --brief /b.md --release "$RELEASE" --walks 'bad id' >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a non-slug walk id must be refused"
  rc=0
  run_carrier "$mate" --brief /b.md --release "$RELEASE" --walks w1 --bot 'Two Words' >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a bot name with whitespace must be refused"
  [ ! -e "$parent/state/refusals-mate.status" ] \
    || fail "a refused carrier run must not write the channel"
  pass "walk-request: invalid requests and main homes are refused before any write"
}

# --- arm and disarm ----------------------------------------------------------

test_arm_and_disarm() {
  local parent mate dispatch send out
  parent=$(make_parent armed)
  mate=$(make_mate armed-mate "$parent")
  dispatch="$parent/fake-dispatch"
  send="$parent/fake-send"
  fake_dispatcher "$dispatch"
  fake_send "$send"
  out=$(FM_HOME="$parent" FM_STATE_OVERRIDE="$parent/state" "$CHECK" arm) \
    || fail "arm must succeed: $out"
  [ -f "$parent/state/walk-request.check.sh" ] || fail "arm must write the shim"
  [ -f "$parent/state/walk-request.check-trust" ] || fail "arm must write the trust binding"
  run_carrier "$mate" --brief /srv/walks/brief.md --release "$RELEASE" \
    --walks armed-step --bot J01Walker >/dev/null || fail "the armed request must publish"
  FM_STATE_OVERRIDE="$parent/state" FM_WALK_REQUEST_DISPATCH="$dispatch" \
    FM_WALK_REQUEST_SEND="$send" bash "$parent/state/walk-request.check.sh" \
    || fail "the armed shim must run"
  wait_for "$dispatch.calls" "--once-key armed-step@$RELEASE" \
    || fail "arming must enable dispatch through the generated shim"
  wait_for "$parent/state/walk-requests/"*.log '__FM_WALK_DISPATCH_EXIT__=0' \
    || fail "the armed dispatch must finish"
  FM_STATE_OVERRIDE="$parent/state" FM_WALK_REQUEST_DISPATCH="$dispatch" \
    FM_WALK_REQUEST_SEND="$send" bash "$parent/state/walk-request.check.sh" \
    || fail "the armed shim must collect the result"
  assert_grep 'target=armed-mate' "$send.calls" "the armed shim returns the outcome"
  out=$(FM_HOME="$parent" FM_STATE_OVERRIDE="$parent/state" "$CHECK" disarm) \
    || fail "disarm must succeed: $out"
  [ ! -e "$parent/state/walk-request.check.sh" ] || fail "disarm must remove the shim"
  [ ! -e "$parent/state/walk-request.check-trust" ] || fail "disarm must remove the trust binding"
  pass "walk-request: arm writes and binds the check; disarm removes both"
}

# --- the MAIN-side sweep -----------------------------------------------------

test_check_dispatches_and_returns_the_outcome() {
  local parent mate dispatch send out
  parent=$(make_parent sweep-main)
  mate=$(make_mate sweep-mate "$parent")
  dispatch="$parent/fake-dispatch"
  send="$parent/fake-send"
  fake_dispatcher "$dispatch"
  fake_send "$send"
  run_carrier "$mate" --brief /srv/walks/brief.md --release "$RELEASE" \
    --walks desk-step,money-step --bot J01Walker >/dev/null \
    || fail "the carrier must succeed"
  # First sweep: intake and spawn (silent on success).
  out=$(run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send")
  [ -z "$out" ] || fail "a successful intake must print nothing: $out"
  wait_for "$dispatch.calls" 'args=' || fail "the dispatcher must have been invoked"
  local log
  for log in "$parent/state/walk-requests/"*.log; do
    wait_for "$log" '__FM_WALK_DISPATCH_EXIT__=0' || fail "each detached dispatch must record its exit"
  done
  # Second sweep: collect and deliver both outcomes (still silent).
  out=$(run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send")
  [ -z "$out" ] || fail "outcome delivery must print nothing: $out"
  wait_for "$send.calls" 'outcome: sent, exit=0: walk green' \
    || fail "the outcome must reach the mate through fm-send"
  assert_grep "target=sweep-mate" "$send.calls" "the outcome goes to the requesting mate"
  assert_grep "desk-step@$RELEASE" "$send.calls" "the outcome names the walk and release"
  assert_grep "money-step@$RELEASE" "$send.calls" "every walk gets its own outcome"
  # The dispatcher saw the once-keys and the walk ownership. grep -F takes
  # the flag-shaped needle after -- so a leading --once-key is a pattern,
  # not an option.
  grep -F -- "--once-key desk-step@$RELEASE" "$dispatch.calls" >/dev/null \
    || fail "the dispatch carries the at-most-once key"
  grep -F -- "--walk-owner sweep-mate" "$dispatch.calls" >/dev/null \
    || fail "the walk claim names the requesting mate"
  grep -F -- "--bot J01Walker" "$dispatch.calls" >/dev/null \
    || fail "the dispatch names the bot"
  # Third sweep: nothing new - no respawn, no duplicate delivery.
  local calls_before sends_before
  calls_before=$(grep -c 'args=' "$dispatch.calls")
  sends_before=$(grep -c 'outcome:' "$send.calls")
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  [ "$(grep -c 'args=' "$dispatch.calls")" = "$calls_before" ] \
    || fail "a delivered record must not respawn the dispatcher"
  [ "$(grep -c 'outcome:' "$send.calls")" = "$sends_before" ] \
    || fail "a delivered outcome must not be delivered twice"
  pass "walk-request: the check dispatches at most once and returns the outcome"
}

test_missing_dispatcher_is_reported_plainly() {
  local parent mate dispatch send out
  parent=$(make_parent absent-main)
  mate=$(make_mate absent-mate "$parent")
  dispatch="$parent/no-such-dispatcher"
  send="$parent/fake-send"
  fake_send "$send"
  run_carrier "$mate" --brief /srv/walks/brief.md --release "$RELEASE" \
    --walks desk-step --bot J01Walker >/dev/null
  out=$(run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send")
  assert_contains "$out" "dispatcher absent" \
    "a missing dispatcher is reported plainly, once"
  assert_grep "dispatcher absent at $dispatch" "$parent/state/walk-requests/"*.record \
    "the failure is durable in the record"
  wait_for "$send.calls" 'outcome:' || fail "the mate still learns the walk was not dispatched"
  assert_grep 'refused: MAIN has no walker dispatcher' "$send.calls" \
    "the refusal outcome names the absent dispatcher"
  out=$(run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send")
  [ -z "$out" ] || fail "the same failure must not be reported twice: $out"
  pass "walk-request: an absent dispatcher is one plain report plus a mate outcome"
}

test_incomplete_and_botless_requests_fail_loudly() {
  local parent mate dispatch send out
  parent=$(make_parent invalid-main)
  mate=$(make_mate invalid-mate "$parent")
  dispatch="$parent/fake-dispatch"
  send="$parent/fake-send"
  fake_dispatcher "$dispatch"
  fake_send "$send"
  # An incomplete typed line (no release) is hand-written: the carrier refuses
  # this shape, so the check's own validation is what protects MAIN.
  printf '%s\n' \
    'note [corr=0123456789abcdef] [at=1793200000]: walk-request: walks=desk-step brief=/srv/walks/brief.md' \
    >> "$parent/state/invalid-mate.status"
  out=$(run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send")
  assert_contains "$out" "incomplete" "an incomplete request is reported"
  wait_for "$send.calls" 'refused: the typed walk request was incomplete' \
    || fail "the mate learns its request was refused"
  # A request with no bot and no default bot.
  run_carrier "$mate" --brief /srv/walks/brief.md --release "$RELEASE" --walks desk-step >/dev/null
  out=$(run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send")
  assert_contains "$out" "no bot" "a botless request is reported"
  wait_for "$send.calls" 'refused: no bot was named' \
    || fail "the mate learns no bot was named"
  [ ! -e "$dispatch.calls" ] || [ ! -s "$dispatch.calls" ] \
    || fail "a refused request must never reach the dispatcher"
  # With a default bot configured, the same request dispatches.
  run_carrier "$mate" --brief /srv/walks/brief.md --release "$RELEASE" --walks desk-step2 >/dev/null
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" \
    FM_WALK_REQUEST_BOT=DefaultWalker >/dev/null
  wait_for "$dispatch.calls" 'DefaultWalker' || fail "the default bot dispatches the request"
  pass "walk-request: incomplete or botless requests fail loudly and never dispatch"
}

test_carrier_without_openssl() {
  local parent mate fakebin tool location out
  parent=$(make_parent fallback-main)
  mate=$(make_mate fallback-mate "$parent")
  fakebin="$parent/path"
  mkdir -p "$fakebin"
  for tool in bash dirname date cksum awk shasum tr cut paste mkdir cat wc sed grep head; do
    location=$(command -v "$tool") || fail "fallback fixture needs $tool"
    ln -s "$location" "$fakebin/$tool"
  done
  out=$(PATH="$fakebin" run_carrier "$mate" --brief /b.md --release "$RELEASE" --walks fallback-step) \
    || fail "the carrier must publish without openssl"
  [[ "$out" =~ corr=[0-9a-f]{16} ]] || fail "the fallback must return a 16-hex correlation id"
  assert_grep 'walks=fallback-step' "$parent/state/fallback-mate.status" \
    "the fallback correlation must permit publishing the request"
  pass "walk-request: correlation generation works without openssl"
}

test_walk_id_boundaries() {
  local parent mate dispatch send walk rc corr long max out
  parent=$(make_parent ids-main)
  mate=$(make_mate ids-mate "$parent")
  dispatch="$parent/fake-dispatch"
  send="$parent/fake-send"
  fake_dispatcher "$dispatch"
  fake_send "$send"
  max=$(printf 'a%063d' 0)
  long="${max}a"
  for walk in _walk .walk -walk "$long"; do
    rc=0
    run_carrier "$mate" --brief /b.md --release "$RELEASE" --walks "$walk" >/dev/null 2>&1 || rc=$?
    expect_code 2 "$rc" "the carrier must reject walk id $walk"
  done
  [ ! -e "$parent/state/ids-mate.status" ] || fail "invalid ids must never publish"
  corr=0
  for walk in _walk .walk -walk "$long"; do
    corr=$((corr + 1))
    printf 'note [corr=%016x]: walk-request: walks=%s brief=/b.md release=%s bot=Walker\n' \
      "$corr" "$walk" "$RELEASE" >> "$parent/state/ids-mate.status"
  done
  out=$(run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send")
  assert_contains "$out" 'invalid walk ids' "MAIN validates handwritten request ids"
  [ ! -e "$dispatch.calls" ] || fail "invalid handwritten ids must not dispatch"
  [ "$(wc -l < "$send.calls")" -eq 4 ] || fail "each invalid request must return a refusal"
  run_carrier "$mate" --brief /b.md --release "$RELEASE" --walks "$max" --bot Walker >/dev/null \
    || fail "a 64-character alphanumeric-leading id must publish"
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  wait_for "$dispatch.calls" "--once-key $max@$RELEASE" || fail "the maximum valid id must dispatch"
  wait_for "$parent/state/walk-requests/"*.log '__FM_WALK_DISPATCH_EXIT__=0' || fail "boundary dispatch must finish"
  pass "walk-request: both boundaries enforce dispatcher-compatible ids"
}

fake_retrying_send() {
  cat > "$1" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$3" >> '$1.attempts'
[ -f '$1.allow' ] || {
  case "\$4" in
    *'walk healthy@'*) [ -f '$1.allow-healthy' ] || exit 12 ;;
    *) exit 12 ;;
  esac
}
printf 'target=%s id=%s text=%s\n' "\$1" "\$3" "\$4" >> '$1.calls'
SH
  chmod +x "$1"
}

test_refusal_delivery_recovers() {
  local kind parent mate dispatch send payload out n
  for kind in incomplete sha short dispatcher bot ids; do
    parent=$(make_parent "retry-$kind-main")
    mate=$(make_mate "retry-$kind-mate" "$parent")
    dispatch="$parent/fake-dispatch"
    send="$parent/fake-send"
    fake_dispatcher "$dispatch"
    fake_retrying_send "$send"
    payload="walks=step brief=/b.md release=$RELEASE bot=Walker"
    case "$kind" in
      incomplete) payload='walks=step brief=/b.md' ;;
      sha) payload='walks=step brief=/b.md release=nope bot=Walker' ;;
      short) payload='walks=step brief=/b.md release=abc bot=Walker' ;;
      dispatcher) dispatch="$parent/missing-dispatch" ;;
      bot) payload="walks=step brief=/b.md release=$RELEASE" ;;
      ids) payload="walks=_step brief=/b.md release=$RELEASE bot=Walker" ;;
    esac
    printf 'note [corr=0123456789abcdef]: walk-request: %s\n' "$payload" > "$parent/state/retry-$kind-mate.status"
    for n in 1 2 3 4; do
      run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
    done
    [ ! -e "$send.calls" ] || fail "an unavailable transport must not deliver"
    [ "$(wc -l < "$send.attempts")" -eq 4 ] || fail "refusal $kind must remain deliverable across outages"
    [ "$(sort -u "$send.attempts" | wc -l)" -eq 1 ] || fail "refusal retries must keep the deterministic delivery id"
    : > "$send.allow"
    run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
    assert_grep 'outcome: refused:' "$send.calls" "refusal $kind reaches the recovered transport"
    run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
    [ "$(wc -l < "$send.calls")" -eq 1 ] || fail "a delivered refusal must be terminal"
    [ ! -e "$dispatch.calls" ] || fail "a refused request must never dispatch"
  done
  pass "walk-request: every refusal survives transport outages until delivered"
}

wait_for_calls() {
  local file=$1 expected=$2 n=0 count
  while :; do
    count=$(wc -l < "$file" 2>/dev/null || printf 0)
    [ "$count" -ge "$expected" ] && return 0
    n=$((n + 1))
    [ "$n" -le 100 ] || return 1
    sleep 0.1
  done
}

test_lost_dispatches_and_delivery_recover_independently() {
  local parent mate dispatch send rec n
  parent=$(make_parent lost-main)
  mate=$(make_mate lost-mate "$parent")
  dispatch="$parent/fake-dispatch"
  send="$parent/fake-send"
  cat > "$dispatch" <<SH
#!/usr/bin/env bash
printf 'args=%s\n' "\$*" >> '$dispatch.calls'
case " \$* " in
  *' --walk lost-'*) kill -KILL "\$PPID"; exit 0 ;;
esac
echo 'healthy result'
SH
  chmod +x "$dispatch"
  fake_retrying_send "$send"
  : > "$send.allow-healthy"
  run_carrier "$mate" --brief /b.md --release "$RELEASE" \
    --walks lost-one,healthy,lost-two --bot Walker >/dev/null || fail "the lost-walk request must publish"
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" \
    FM_WALK_REQUEST_NOW=4102444800 >/dev/null
  wait_for_calls "$dispatch.calls" 3 || fail "all initial walks must dispatch"
  wait_for "$parent/state/walk-requests/"*.healthy.log '__FM_WALK_DISPATCH_EXIT__=0' \
    || fail "the healthy dispatch must finish"
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" \
    FM_WALK_REQUEST_NOW=4102444800 >/dev/null
  wait_for_calls "$dispatch.calls" 5 || fail "each lost walk must get its own recovery attempt"
  for n in 1 2 3 4; do
    run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" \
      FM_WALK_REQUEST_NOW=4102444800 >/dev/null
  done
  [ "$(wc -l < "$send.calls")" -eq 1 ] || fail "the healthy sibling must deliver while lost outcomes remain pending"
  : > "$send.allow"
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" \
    FM_WALK_REQUEST_NOW=4102444800 >/dev/null
  [ "$(wc -l < "$send.calls")" -eq 3 ] || fail "both exhausted dispatches and the successful sibling must return outcomes"
  [ "$(grep -c 'no completion was recorded after one recovery attempt' "$send.calls")" -eq 2 ] \
    || fail "each exhausted dispatch must return an explicit failure"
  assert_grep 'sent, exit=0: healthy result' "$send.calls" "the successful sibling retains its result"
  for rec in "$parent/state/walk-requests/"*.record; do
    grep -Fxq 'phase=delivered' "$rec" || fail "out-of-order delivery must complete the request"
  done
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" \
    FM_WALK_REQUEST_NOW=4102444800 >/dev/null
  [ "$(wc -l < "$send.calls")" -eq 3 ] || fail "completed outcomes must not resend"
  [ "$(wc -l < "$dispatch.calls")" -eq 5 ] || fail "each lost walk must have at most one recovery attempt"
  pass "walk-request: lost walks fail explicitly and delivery retries remain independent"
}

test_carrier_writes_the_typed_request
test_carrier_refusals
test_carrier_without_openssl
test_walk_id_boundaries
test_arm_and_disarm
test_check_dispatches_and_returns_the_outcome
test_missing_dispatcher_is_reported_plainly
test_incomplete_and_botless_requests_fail_loudly
test_refusal_delivery_recovers
test_lost_dispatches_and_delivery_recover_independently

echo "# fm-walk-request.test.sh: all assertions passed"
