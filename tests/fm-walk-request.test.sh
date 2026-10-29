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
  mkdir -p "$mate/state" "$mate/data/walk-briefs" "$parent/state"
  printf 'walk brief\n' > "$mate/data/walk-briefs/brief.md"
  printf '%s\n' "$1" > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  printf 'kind=secondmate\nhome=%s\n' "$mate" > "$parent/state/$1.meta"
  printf '%s\n' "$mate"
}

make_parent() {  # <name>
  local parent="$TMP_ROOT/$1"
  mkdir -p "$parent/state" "$parent/data/from-main/walk-lists"
  printf 'shared walk brief\n' > "$parent/data/from-main/walk-lists/brief.md"
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

# A bounded sweep may leave intake or delivery for the next watcher tick.
# Count the fake transport's observable deliveries, not internal record phases.
check_until_calls() {  # <parent-home> <calls-file> <count> [env assignments...]
  local parent=$1 calls=$2 expected=$3 n
  shift 3
  for n in {1..20}; do
    run_check "$parent" "$@" || fail "walk-request sweep failed before delivery completed"
    if [ -f "$calls" ] && [ "$(wc -l < "$calls")" -ge "$expected" ]; then
      return 0
    fi
  done
  fail "walk-request deliveries did not reach $expected across bounded sweeps"
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
printf 'target=%s id=%s text=%s\n' "\$1" "\$3" "\$(printf '%s' "\$4" | tr '\n' '|')" >> '$1.calls'
printf '%s' "\$4" > '$1.'"\$3"'.message'
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
  out=$(run_carrier "$mate" --brief "$parent/data/from-main/walk-lists/brief.md" --release "$RELEASE" \
    --walks desk-step,money-step --bot J01Walker) \
    || fail "the carrier must succeed on a secondmate home"
  assert_contains "$out" "corr=" "the carrier prints its correlation id"
  assert_contains "$out" "once-key=desk-step@$RELEASE" "the carrier prints the first once-key"
  assert_contains "$out" "once-key=money-step@$RELEASE" "the carrier prints the second once-key"
  assert_grep "walk-request: walks=desk-step,money-step brief=$parent/data/from-main/walk-lists/brief.md" \
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
  run_carrier "$parent" --brief "$parent/data/from-main/walk-lists/brief.md" --release "$RELEASE" --walks w1 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "the carrier must refuse a main home"
  # Invalid fields are refused before anything is written.
  rc=0
  run_carrier "$mate" --brief relative.md --release "$RELEASE" --walks w1 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a relative brief path must be refused"
  rc=0
  run_carrier "$mate" --brief "$parent/data/from-main/walk-lists/brief.md" --release nothex --walks w1 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a non-hex release must be refused"
  rc=0
  run_carrier "$mate" --brief "$parent/data/from-main/walk-lists/brief.md" --release "$RELEASE" --walks 'bad id' >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a non-slug walk id must be refused"
  rc=0
  run_carrier "$mate" --brief "$parent/data/from-main/walk-lists/brief.md" --release "$RELEASE" --walks w1 --bot 'Two Words' >/dev/null 2>&1 || rc=$?
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
  run_carrier "$mate" --brief "$parent/data/from-main/walk-lists/brief.md" --release "$RELEASE" \
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
  run_carrier "$mate" --brief "$parent/data/from-main/walk-lists/brief.md" --release "$RELEASE" \
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
  local snapshot
  snapshot=$(head -1 "$dispatch.calls")
  snapshot=${snapshot#args=}; snapshot=${snapshot%% *}
  case "$snapshot" in "$parent/data/walk-requests/"*/brief.md) ;; *) fail "local requests must dispatch MAIN's snapshot" ;; esac
  cmp "$parent/data/from-main/walk-lists/brief.md" "$snapshot" || fail "the local snapshot must preserve the approved source bytes"
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
  run_carrier "$mate" --brief "$parent/data/from-main/walk-lists/brief.md" --release "$RELEASE" \
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
    "note [corr=0123456789abcdef] [at=1793200000]: walk-request: walks=desk-step brief=$parent/data/from-main/walk-lists/brief.md" \
    >> "$parent/state/invalid-mate.status"
  out=$(run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send")
  assert_contains "$out" "incomplete" "an incomplete request is reported"
  wait_for "$send.calls" 'refused: the typed walk request was incomplete' \
    || fail "the mate learns its request was refused"
  # A request with no bot and no default bot.
  run_carrier "$mate" --brief "$parent/data/from-main/walk-lists/brief.md" --release "$RELEASE" --walks desk-step >/dev/null
  out=$(run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send")
  assert_contains "$out" "no bot" "a botless request is reported"
  wait_for "$send.calls" 'refused: no bot was named' \
    || fail "the mate learns no bot was named"
  [ ! -e "$dispatch.calls" ] || [ ! -s "$dispatch.calls" ] \
    || fail "a refused request must never reach the dispatcher"
  # With a default bot configured, the same request dispatches.
  run_carrier "$mate" --brief "$parent/data/from-main/walk-lists/brief.md" --release "$RELEASE" --walks desk-step2 >/dev/null
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
  for tool in bash dirname date cksum awk shasum tr cut paste mkdir cat wc sed grep head python3; do
    location=$(command -v "$tool") || fail "fallback fixture needs $tool"
    ln -s "$location" "$fakebin/$tool"
  done
  out=$(PATH="$fakebin" run_carrier "$mate" --brief "$parent/data/from-main/walk-lists/brief.md" --release "$RELEASE" --walks fallback-step) \
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
    run_carrier "$mate" --brief "$parent/data/from-main/walk-lists/brief.md" --release "$RELEASE" --walks "$walk" >/dev/null 2>&1 || rc=$?
    expect_code 2 "$rc" "the carrier must reject walk id $walk"
  done
  [ ! -e "$parent/state/ids-mate.status" ] || fail "invalid ids must never publish"
  corr=0
  for walk in _walk .walk -walk "$long"; do
    corr=$((corr + 1))
    printf "note [corr=%016x]: walk-request: walks=%s brief=$parent/data/from-main/walk-lists/brief.md release=%s bot=Walker\n" \
      "$corr" "$walk" "$RELEASE" >> "$parent/state/ids-mate.status"
  done
  out=$(check_until_calls "$parent" "$send.calls" 4 FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send") \
    || fail "invalid walk-id refusals must complete successfully"
  assert_contains "$out" 'invalid walk ids' "MAIN validates handwritten request ids"
  [ ! -e "$dispatch.calls" ] || fail "invalid handwritten ids must not dispatch"
  [ "$(wc -l < "$send.calls")" -eq 4 ] || fail "each invalid request must return a refusal"
  run_carrier "$mate" --brief "$parent/data/from-main/walk-lists/brief.md" --release "$RELEASE" --walks "$max" --bot Walker >/dev/null \
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
printf 'target=%s id=%s text=%s\n' "\$1" "\$3" "\$(printf '%s' "\$4" | tr '\n' '|')" >> '$1.calls'
printf '%s' "\$4" > '$1.'"\$3"'.message'
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
    payload="walks=step brief=$parent/data/from-main/walk-lists/brief.md release=$RELEASE bot=Walker"
    case "$kind" in
      incomplete) payload="walks=step brief=$parent/data/from-main/walk-lists/brief.md" ;;
      sha) payload="walks=step brief=$parent/data/from-main/walk-lists/brief.md release=nope bot=Walker" ;;
      short) payload="walks=step brief=$parent/data/from-main/walk-lists/brief.md release=abc bot=Walker" ;;
      dispatcher) dispatch="$parent/missing-dispatch" ;;
      bot) payload="walks=step brief=$parent/data/from-main/walk-lists/brief.md release=$RELEASE" ;;
      ids) payload="walks=_step brief=$parent/data/from-main/walk-lists/brief.md release=$RELEASE bot=Walker" ;;
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
  run_carrier "$mate" --brief "$parent/data/from-main/walk-lists/brief.md" --release "$RELEASE" \
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

test_launch_progress_survives_interruption() {
  local parent mate dispatch send fakebin real_mv out corr rc rec
  parent=$(make_parent interrupted-main)
  mate=$(make_mate interrupted-mate "$parent")
  dispatch="$parent/fake-dispatch"
  send="$parent/fake-send"
  fake_dispatcher "$dispatch"
  fake_send "$send"
  out=$(run_carrier "$mate" --brief "$parent/data/from-main/walk-lists/brief.md" --release "$RELEASE" --walks first,second --bot Walker)
  corr=$(printf '%s\n' "$out" | sed -n 's/^corr=//p')
  fakebin="$parent/path"
  mkdir -p "$fakebin"
  real_mv=$(command -v mv)
  : > "$parent/interrupt"
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
'$real_mv' "\$@" || exit \$?
last=\${!#}
case "\$last" in
  '$parent/state/walk-requests/'*.record)
    phase=\$(sed -n 's/^phase=//p' "\$last")
    spawned=\$(sed -n 's/^spawned=//p' "\$last")
    if [ "\$phase" = dispatching ]; then
      [ -n "\$spawned" ] || : > '$parent/invalid-publication'
      if [ -f '$parent/interrupt' ]; then
        rm '$parent/interrupt'
        kill -TERM "\$PPID"
      fi
    fi
    ;;
esac
SH
  chmod +x "$fakebin/mv"
  rc=0
  run_check "$parent" PATH="$fakebin:$PATH" FM_WALK_REQUEST_DISPATCH="$dispatch" \
    FM_WALK_REQUEST_SEND="$send" >/dev/null 2>&1 || rc=$?
  expect_code 143 "$rc" "the check must be interrupted at the launch-progress commit"
  [ ! -e "$parent/invalid-publication" ] || fail "phase and launched walks must publish atomically"
  rec="$parent/state/walk-requests/$corr.record"
  grep -Fxq phase=dispatching "$rec" || fail "launch progress must survive interruption"
  grep -Fxq spawned=first "$rec" || fail "the interrupted snapshot must identify its scheduled walk"
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" \
    FM_WALK_REQUEST_NOW=4102444800 >/dev/null
  wait_for "$parent/state/walk-requests/$corr.second.log" '__FM_WALK_DISPATCH_EXIT__=0' \
    || fail "the unstarted sibling must dispatch after resuming"
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" \
    FM_WALK_REQUEST_NOW=4102444800 >/dev/null
  wait_for "$parent/state/walk-requests/$corr.first.log" '__FM_WALK_DISPATCH_EXIT__=0' \
    || fail "the interrupted scheduled walk must recover"
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" \
    FM_WALK_REQUEST_NOW=4102444800 >/dev/null
  [ "$(wc -l < "$dispatch.calls")" -eq 2 ] || fail "resuming must dispatch every walk once"
  [ "$(wc -l < "$send.calls")" -eq 2 ] || fail "both resumed outcomes must return"
  grep -Fxq phase=delivered "$rec" || fail "the resumed request must finish"
  pass "walk-request: atomic launch progress survives interruption and resumes every sibling"
}

test_launch_is_portable_and_failures_return() {
  local parent mate dispatch send fakebin corr out
  parent=$(make_parent portable-main)
  mate=$(make_mate portable-mate "$parent")
  dispatch="$parent/fake-dispatch"
  send="$parent/fake-send"
  fakebin="$parent/path"
  mkdir -p "$fakebin"
  fake_dispatcher "$dispatch"
  fake_send "$send"
  cat > "$fakebin/setsid" <<SH
#!/usr/bin/env bash
: > '$parent/setsid-called'
exit 127
SH
  chmod +x "$fakebin/setsid"
  out=$(run_carrier "$mate" --brief "$parent/data/from-main/walk-lists/brief.md" --release "$RELEASE" --walks portable --bot Walker)
  corr=$(printf '%s\n' "$out" | sed -n 's/^corr=//p')
  run_check "$parent" PATH="$fakebin:$PATH" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  wait_for "$parent/state/walk-requests/$corr.portable.log" '__FM_WALK_DISPATCH_EXIT__=0' \
    || fail "dispatch must detach and finish without a setsid utility"
  [ ! -e "$parent/setsid-called" ] || fail "portable detachment must not invoke setsid"
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  assert_grep 'walk portable@' "$send.calls" "the portable dispatch returns its result"
  local real_python
  real_python=$(command -v python3)
  cat > "$fakebin/python3" <<SH
#!/usr/bin/env bash
[ "\$1" != - ] || [ "\$#" -ne 5 ] || exit 23
exec '$real_python' "\$@"
SH
  chmod +x "$fakebin/python3"
  out=$(run_carrier "$mate" --brief "$parent/data/from-main/walk-lists/brief.md" --release "$RELEASE" --walks launch-error --bot Walker)
  corr=$(printf '%s\n' "$out" | sed -n 's/^corr=//p')
  run_check "$parent" PATH="$fakebin:$PATH" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  assert_grep 'dispatch failed (exit=23)' "$send.calls" "a launcher failure must return its actual status"
  [ "$(wc -l < "$dispatch.calls")" -eq 1 ] || fail "a failed launcher must never reach the dispatcher"
  grep -Fxq phase=delivered "$parent/state/walk-requests/$corr.record" || fail "launch failure delivery must finish the request"
  cat > "$dispatch" <<SH
#!/usr/bin/env bash
printf 'args=%s\n' "\$*" >> '$dispatch.calls'
kill -KILL "\$PPID"
SH
  out=$(run_carrier "$mate" --brief "$parent/data/from-main/walk-lists/brief.md" --release "$RELEASE" --walks recovery-error --bot Walker)
  corr=$(printf '%s\n' "$out" | sed -n 's/^corr=//p')
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  wait_for_calls "$dispatch.calls" 2 || fail "the recovery fixture must lose its first dispatcher"
  run_check "$parent" PATH="$fakebin:$PATH" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" \
    FM_WALK_REQUEST_NOW=4102444800 >/dev/null
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  [ "$(grep -c 'dispatch failed (exit=23)' "$send.calls")" -eq 2 ] || fail "initial and recovery launch failures must both return"
  grep -Fxq phase=delivered "$parent/state/walk-requests/$corr.record" || fail "recovery launch failure must finish its request"
  pass "walk-request: detachment works without setsid and launch failures return explicitly"
}

test_slow_deliveries_are_bounded_and_fair() {
  local parent mate dispatch send n corr walks out
  parent=$(make_parent fair-main)
  dispatch="$parent/fake-dispatch"
  send="$parent/fake-send"
  fake_dispatcher "$dispatch"
  cat > "$send" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$(printf '%s' "\$4" | tr '\n' '|')" >> '$send.attempts'
if [ ! -f '$send.allow' ]; then sleep 10; exit 12; fi
printf '%s\n' "\$(printf '%s' "\$4" | tr '\n' '|')" >> '$send.calls'
SH
  chmod +x "$send"
  for n in 1 2 3; do
    mate=$(make_mate "fair-mate-$n" "$parent")
    printf -v corr '%016x' "$n"
    case "$n" in
      1) walks=first,middle,last ;;
      2) walks=other ;;
      3) walks=refusal ;;
    esac
    if [ "$n" -eq 3 ]; then
      printf 'note [corr=%s]: walk-request: walks=refusal\n' "$corr" > "$parent/state/fair-mate-$n.status"
    else
      printf "note [corr=%s]: walk-request: walks=%s brief=$parent/data/from-main/walk-lists/brief.md release=%s bot=Walker\n" \
        "$corr" "$walks" "$RELEASE" > "$parent/state/fair-mate-$n.status"
    fi
  done
  . "$ROOT/bin/fm-timeout-lib.sh"
  for n in {1..8}; do
    FM_HOME="$parent" FM_STATE_OVERRIDE="$parent/state" FM_CHECK_TIMEOUT=4 \
      FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" \
      FM_WALK_REQUEST_SEND_BOUND=25 fm_run_timed 4 "$CHECK" check > "$parent/check-output" \
      || fail "a sweep must yield inside the registered check's bound"
  done
  for walks in first middle last other request; do
    assert_grep "walk $walks@" "$send.attempts" "pending outcome $walks must get a turn despite stalled transports"
  done
  : > "$send.allow"
  check_until_calls "$parent" "$send.calls" 5 FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  [ "$(wc -l < "$send.calls")" -eq 5 ] || fail "every pending walk and refusal must deliver after recovery"
  out=$(run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send")
  [ -z "$out" ] || fail "fully delivered records must be quiet"
  [ "$(wc -l < "$send.calls")" -eq 5 ] || fail "completed records must not resend"
  pass "walk-request: slow sends stay within budget and rotate across records, refusals, and sibling walks"
}

test_brief_disclosure_boundaries() {
  local parent mate other dispatch send bad n=0 rc before alias out real_python fakebin corr
  parent=$(make_parent private-main)
  mate=$(make_mate private-mate "$parent")
  other=$(make_mate other-mate "$parent")
  dispatch="$parent/fake-dispatch"
  send="$parent/fake-send"
  fake_dispatcher "$dispatch"
  fake_send "$send"
  mkdir -p "$parent/config" "$parent/state" "$mate/data/walk-briefs/config" "$mate/data/walk-briefs/state"
  for bad in "$parent/.env" "$parent/config/brief.md" "$parent/state/brief.md" \
    "$mate/data/walk-briefs/.hidden.md" "$mate/data/walk-briefs/config/brief.md" \
    "$mate/data/walk-briefs/state/brief.md" "$parent/outside.md"; do
    printf 'private material\n' > "$bad"
  done
  alias="$mate/data/walk-briefs/escape.md"
  ln -s "$parent/.env" "$alias"
  for bad in "$parent/.env" "$parent/config/brief.md" "$parent/state/brief.md" \
    "$mate/data/walk-briefs/.hidden.md" "$mate/data/walk-briefs/config/brief.md" \
    "$mate/data/walk-briefs/state/brief.md" "$parent/outside.md" \
    "$other/data/walk-briefs/brief.md" "$alias"; do
    rc=0
    run_carrier "$mate" --brief "$bad" --release "$RELEASE" --walks private --bot Walker >/dev/null 2>&1 || rc=$?
    expect_code 2 "$rc" "private or out-of-scope briefs must be refused before publishing"
    n=$((n + 1))
    printf 'note [corr=%016x]: walk-request: walks=private brief=%s release=%s bot=Walker\n' \
      "$n" "$bad" "$RELEASE" >> "$parent/state/private-mate.status"
  done
  check_until_calls "$parent" "$send.calls" "$n" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  [ ! -e "$dispatch.calls" ] || fail "forged private-file requests must never dispatch"
  [ "$(wc -l < "$send.calls")" -eq "$n" ] || fail "MAIN must return every private-file refusal"
  before=$(wc -l < "$parent/state/private-mate.status")
  rc=0
  run_carrier "$mate" --brief "$mate/data/walk-briefs/brief.md" --release "$RELEASE" \
    --walks 'first;second' --bot Walker >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "the undocumented semicolon alias must be refused"
  [ "$(wc -l < "$parent/state/private-mate.status")" -eq "$before" ] || fail "invalid list syntax must not publish"
  ln -s "$mate/data/walk-briefs/brief.md" "$mate/data/walk-briefs/approved.md"
  out=$(run_carrier "$mate" --brief "$mate/data/walk-briefs/approved.md" --release "$RELEASE" --walks approved --bot Walker) \
    || fail "an in-scope symlink must resolve to its approved file"
  assert_grep "brief=$mate/data/walk-briefs/brief.md" "$parent/state/private-mate.status" "the carrier publishes the resolved file"
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  wait_for "$dispatch.calls" '--walk approved' || fail "the requesting mate's approved brief must dispatch"
  corr=$(printf '%s\n' "$out" | sed -n 's/^corr=//p')
  wait_for "$parent/state/walk-requests/$corr.approved.log" '__FM_WALK_DISPATCH_EXIT__=0' || fail "approved dispatch must finish"
  fakebin="$parent/path"
  mkdir -p "$fakebin"
  real_python=$(command -v python3)
  cat > "$fakebin/python3" <<SH
#!/usr/bin/env bash
if [ "\$1" = - ] && [ "\$#" -eq 5 ]; then ln -sf '$parent/.env' '$parent/data/walk-requests/'"\$3"'/brief.md'; fi
exec '$real_python' "\$@"
SH
  chmod +x "$fakebin/python3"
  out=$(run_carrier "$mate" --brief "$mate/data/walk-briefs/brief.md" --release "$RELEASE" --walks swapped --bot Walker)
  corr=$(printf '%s\n' "$out" | sed -n 's/^corr=//p')
  run_check "$parent" PATH="$fakebin:$PATH" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  wait_for "$parent/state/walk-requests/$corr.swapped.log" '__FM_WALK_DISPATCH_EXIT__=2' \
    || fail "dispatch must recheck a brief swapped after intake"
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  [ "$(wc -l < "$dispatch.calls")" -eq 1 ] || fail "a swapped private brief must never reach the dispatcher"
  assert_grep 'refused: brief snapshot is private' "$send.calls" "the mate learns why dispatch refused the swapped file"
  pass "walk-request: private files, cross-mate paths, symlink escapes, and dispatch-time swaps are refused"
}

test_complete_reports_survive_recovery_and_return_with_pointers() {
  local mode parent mate dispatch send out corr log message n
  for mode in complete recovery large; do
    parent=$(make_parent "report-$mode-main")
    mate=$(make_mate "report-$mode-mate" "$parent")
    dispatch="$parent/fake-dispatch"
    send="$parent/fake-send"
    fake_send "$send"
    printf 'Walk report\nBLOCKED: login failed\n' > "$parent/report"
    for n in {1..20}; do printf 'Detailed observation %s: the login remains blocked.\n' "$n" >> "$parent/report"; done
    if [ "$mode" = large ]; then
      for n in {1..400}; do printf 'Long observation %s: retained in the complete report file.\n' "$n" >> "$parent/report"; done
    fi
    printf 'UNVERIFIED: this report requires review\n' >> "$parent/report"
    cat > "$dispatch" <<SH
#!/usr/bin/env bash
printf 'dispatch\n' >> '$dispatch.calls'
if [ -f '$dispatch.sent' ]; then echo 'grok-bot: once-key already sent'; exit 0; fi
: > '$dispatch.sent'
cat '$parent/report'
if [ '$mode' = recovery ]; then kill -KILL "\$PPID"; fi
SH
    chmod +x "$dispatch"
    out=$(run_carrier "$mate" --brief "$mate/data/walk-briefs/brief.md" --release "$RELEASE" --walks report --bot Walker)
    corr=$(printf '%s\n' "$out" | sed -n 's/^corr=//p')
    log="$parent/state/walk-requests/$corr.report.log"
    run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
    if [ "$mode" = recovery ]; then
      wait_for "$log" 'UNVERIFIED: this report requires review' || fail "the original dispatch must emit its full report"
      run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" FM_WALK_REQUEST_NOW=4102444800 >/dev/null
    fi
    wait_for "$log" '__FM_WALK_DISPATCH_EXIT__=0' || fail "the dispatch must record completion"
    run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
    message=$(cat "$send."*.message)
    assert_contains "$message" $'Walk report\nBLOCKED: login failed' "multiline findings must reach the mate"
    assert_contains "$message" "Full report (MAIN): $log" "every returned report must include its full-file pointer"
    assert_contains "$(cat "$log")" "$(cat "$parent/report")" "the complete report must survive in its referenced file"
    if [ "$mode" = large ]; then
      [ "${#message}" -lt 9000 ] || fail "a large inline report must stay bounded while preserving its pointer"
    else
      assert_contains "$message" "$(cat "$parent/report")" "the entire report must return within the inline bound"
    fi
    if [ "$mode" = recovery ]; then
      [ "$(wc -l < "$dispatch.calls")" -eq 2 ] || fail "the lost wrapper must retry with its once-key"
      assert_contains "$message" 'once-key already sent' "recovery diagnostics must accompany the preserved original report"
    fi
  done
  pass "walk-request: whole multiline reports survive recovery and return with bounded inline text and full-file pointers"
}

test_historical_discovery_reserves_processing_and_advances() {
  local parent mate dispatch send fakebin real_grep n out
  parent=$(make_parent history-main)
  mate=$(make_mate history-mate "$parent")
  dispatch="$parent/fake-dispatch"
  send="$parent/fake-send"
  fake_dispatcher "$dispatch"
  fake_send "$send"
  mkdir -p "$parent/state/walk-requests"
  printf 'schema=fm-walk-request-v1\ncorr=0000000000000001\nphase=delivered\n' > "$parent/state/walk-requests/0000000000000001.record"
  printf '%s\n' schema=fm-walk-request-v1 corr=ffffffffffffffff mate=history-mate walks=ready \
    "brief=$mate/data/walk-briefs/brief.md" "release=$RELEASE" bot=Walker phase=dispatching \
    spawned=ready delivered= retried= > "$parent/state/walk-requests/ffffffffffffffff.record"
  printf 'pending result\n__FM_WALK_DISPATCH_EXIT__=0\n' > "$parent/state/walk-requests/ffffffffffffffff.ready.log"
  for n in {1..100}; do
    printf 'note [corr=0000000000000001]: walk-request: walks=old brief=%s release=%s bot=Walker\n' \
      "$mate/data/walk-briefs/brief.md" "$RELEASE" >> "$parent/state/history-mate.status"
  done
  run_carrier "$mate" --brief "$mate/data/walk-briefs/brief.md" --release "$RELEASE" --walks late --bot Walker >/dev/null
  fakebin="$parent/path"
  mkdir -p "$fakebin"
  real_grep=$(command -v grep)
  cat > "$fakebin/grep" <<SH
#!/usr/bin/env bash
if [ "\$1" = -oE ]; then sleep 0.03; fi
exec '$real_grep' "\$@"
SH
  chmod +x "$fakebin/grep"
  . "$ROOT/bin/fm-timeout-lib.sh"
  FM_HOME="$parent" FM_STATE_OVERRIDE="$parent/state" FM_CHECK_TIMEOUT=4 PATH="$fakebin:$PATH" \
    FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" \
    fm_run_timed 4 "$CHECK" check >/dev/null || fail "history discovery must yield within the check bound"
  assert_grep 'pending result' "$send.calls" "pending delivery must progress while history discovery is still busy"
  for n in {1..8}; do
    run_check "$parent" PATH="$fakebin:$PATH" FM_CHECK_TIMEOUT=4 FM_WALK_REQUEST_DISPATCH="$dispatch" \
      FM_WALK_REQUEST_SEND="$send" >/dev/null
    [ ! -e "$dispatch.calls" ] || break
  done
  wait_for "$dispatch.calls" '--walk late' || fail "discovery must eventually advance beyond historical requests"
  wait_for "$parent/state/walk-requests/"*.late.log '__FM_WALK_DISPATCH_EXIT__=0' || fail "the late request must complete"
  out=$(run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send")
  [ -z "$out" ] || fail "successful discovery and delivery must be quiet"
  assert_grep 'walk late@' "$send.calls" "the late request's result must return"
  pass "walk-request: historical discovery leaves processing time and eventually reaches new requests"
}

test_inline_remote_briefs_and_size_limits() {
  local parent mate dispatch send out corr remote_log snapshot delta payload rc n file fakebin real_grep
  parent=$(make_parent inline-main)
  mate=$(make_mate inline-mate "$parent")
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=main\n' > "$mate/.fm-secondmate-parent"
  printf 'kind=secondmate\nremote_host=server\nhome=/not-on-main/mate\n' > "$parent/state/inline-mate.meta"
  dispatch="$parent/fake-dispatch"
  send="$parent/fake-send"
  fake_send "$send"
  cat > "$dispatch" <<SHDISPATCH
#!/usr/bin/env bash
printf '%s\n' "\$1" >> '$dispatch.calls'
cat "\$1" > '$dispatch.received'
echo 'remote walk completed'
SHDISPATCH
  chmod +x "$dispatch"
  python3 - "$mate/data/walk-briefs/brief.md" <<'PYTHON'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes('Remote café brief\n'.encode() + b'x' * (65536 - len('Remote café brief\n'.encode())))
PYTHON
  cp "$mate/data/walk-briefs/brief.md" "$parent/expected"
  out=$(run_carrier "$mate" --brief "$mate/data/walk-briefs/brief.md" --release "$RELEASE" --walks remote --bot Walker) \
    || fail "a remote binding must publish its local UTF-8 brief inline"
  corr=$(printf '%s\n' "$out" | sed -n 's/^corr=//p')
  remote_log="$mate/state/parent-replies.status"
  assert_grep 'brief64=' "$remote_log" "the remote request carries inline content"
  delta="$parent/delta"
  FM_HOME="$mate" "$ROOT/bin/fm-remote-delta-read.sh" state/parent-replies.status 0 \
    e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 0 > "$delta" \
    || fail "the existing remote reader must carry a maximum-size inline request"
  assert_grep 'status=delta' "$delta" "the inline request must fit the remote channel bound"
  sed '1,/^$/d' "$delta" > "$parent/state/inline-mate.status"
  rm "$mate/data/walk-briefs/brief.md"
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  wait_for "$parent/state/walk-requests/$corr.remote.log" '__FM_WALK_DISPATCH_EXIT__=0' || fail "the remote inline request must finish"
  snapshot="$parent/data/walk-requests/$corr/brief.md"
  assert_equals "$snapshot" "$(cat "$dispatch.calls")" "MAIN dispatches its request snapshot"
  cmp "$parent/expected" "$snapshot" || fail "the 64 KiB UTF-8 snapshot must preserve every byte"
  cmp "$parent/expected" "$dispatch.received" || fail "the dispatcher must receive the remote content without opening the source path"
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  assert_grep 'remote walk completed' "$send.calls" "the remote result must return"
  for n in oversize binary invalid-utf8; do
    file="$mate/data/walk-briefs/$n.md"
    python3 - "$file" "$n" <<'PYTHON'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes({'oversize': b'x' * 65537, 'binary': b'brief\x00secret', 'invalid-utf8': b'\xff'}[sys.argv[2]])
PYTHON
    rc=0
    run_carrier "$mate" --brief "$file" --release "$RELEASE" --walks "$n" --bot Walker >/dev/null 2>&1 || rc=$?
    expect_code 2 "$rc" "the carrier must refuse $n content before publishing"
    payload=$(python3 - "$file" <<'PYTHON'
import base64
from pathlib import Path
import sys
print(base64.b64encode(Path(sys.argv[1]).read_bytes()).decode())
PYTHON
)
    case "$n" in oversize) out=1111111111111111 ;; binary) out=2222222222222222 ;; *) out=3333333333333333 ;; esac
    printf 'note [corr=%s]: walk-request: walks=%s brief64=%s release=%s bot=Walker\n' \
      "$out" "$n" "$payload" "$RELEASE" >> "$parent/state/inline-mate.status"
  done
  printf 'note [corr=4444444444444444]: walk-request: walks=remote-path brief=%s release=%s bot=Walker\n' \
    "$parent/data/from-main/walk-lists/brief.md" "$RELEASE" >> "$parent/state/inline-mate.status"
  # Force discovery to span sweeps even on a fast host. The oracle remains
  # four refused inputs plus the successful remote walk, each delivered once.
  fakebin="$parent/slow-intake"
  mkdir -p "$fakebin"
  real_grep=$(command -v grep)
  cat > "$fakebin/grep" <<SH
#!/usr/bin/env bash
if [ "\$1" = -oE ]; then sleep 1; fi
exec '$real_grep' "\$@"
SH
  chmod +x "$fakebin/grep"
  check_until_calls "$parent" "$send.calls" 5 PATH="$fakebin:$PATH" FM_CHECK_TIMEOUT=4 \
    FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  [ "$(wc -l < "$remote_log")" -eq 1 ] || fail "refused content must never publish on the remote channel"
  [ "$(wc -l < "$dispatch.calls")" -eq 1 ] || fail "MAIN must refuse invalid inline content and remote path-only requests"
  [ "$(wc -l < "$send.calls")" -eq 5 ] || fail "every invalid remote request must receive its refusal"
  pass "walk-request: remote UTF-8 briefs travel inline up to 64 KiB and invalid content is refused at both boundaries"
}

test_launch_refreshes_stale_attempt_without_losing_output() {
  local parent mate dispatch send corr log snapshot
  parent=$(make_parent freshness-main)
  mate=$(make_mate freshness-mate "$parent")
  dispatch="$parent/fake-dispatch"
  send="$parent/fake-send"
  fake_send "$send"
  corr=1234567890abcdef
  mkdir -p "$parent/state/walk-requests" "$parent/data/walk-requests/$corr"
  snapshot="$parent/data/walk-requests/$corr/brief.md"
  cp "$mate/data/walk-briefs/brief.md" "$snapshot"
  printf '%s\n' schema=fm-walk-request-v1 "corr=$corr" mate=freshness-mate walks=slow \
    "brief=$mate/data/walk-briefs/brief.md" "release=$RELEASE" bot=Walker phase=dispatching \
    spawned=slow delivered= retried= > "$parent/state/walk-requests/$corr.record"
  log="$parent/state/walk-requests/$corr.slow.log"
  printf 'preserved report bytes\n' > "$log"
  touch -t 200001010000 "$log"
  cat > "$dispatch" <<SHDISPATCH
#!/usr/bin/env bash
: > '$dispatch.started'
for ((n=0; n<200; n++)); do
  [ ! -f '$dispatch.finish' ] || { echo 'eventual successful report'; exit 0; }
  sleep 0.05
done
exit 8
SHDISPATCH
  chmod +x "$dispatch"
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  wait_for "$parent/state/walk-requests/$corr.record" 'retried=slow' || fail "the scheduled walk must enter recovery"
  local n=0
  until [ -f "$dispatch.started" ]; do
    n=$((n + 1)); [ "$n" -lt 100 ] || fail "the first actual launch must start"; sleep 0.05
  done
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  [ ! -e "$send.calls" ] || fail "a fresh recovery must not be declared exhausted while its dispatcher runs"
  assert_grep 'preserved report bytes' "$log" "refreshing freshness must preserve previous report bytes"
  : > "$dispatch.finish"
  wait_for "$log" '__FM_WALK_DISPATCH_EXIT__=0' || fail "the running recovery must finish normally"
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  assert_grep 'eventual successful report' "$send.calls" "the eventual result must reach the mate"
  [ "$(wc -l < "$send.calls")" -eq 1 ] || fail "only the successful result may be delivered"
  pass "walk-request: recovery refreshes attempt freshness and preserves the running walk's eventual result"
}

test_partial_launch_refuses_only_unstarted_walks() {
  local parent mate dispatch send corr out fakebin real_python snapshot rec
  parent=$(make_parent partial-main)
  mate=$(make_mate partial-mate "$parent")
  dispatch="$parent/fake-dispatch"
  send="$parent/fake-send"
  fake_send "$send"
  cat > "$dispatch" <<SHDISPATCH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$dispatch.calls'
echo 'first walk complete'
SHDISPATCH
  chmod +x "$dispatch"
  out=$(run_carrier "$mate" --brief "$mate/data/walk-briefs/brief.md" --release "$RELEASE" --walks first,second,third --bot Walker)
  corr=$(printf '%s\n' "$out" | sed -n 's/^corr=//p')
  fakebin="$parent/path"
  mkdir -p "$fakebin"
  real_python=$(command -v python3)
  cat > "$fakebin/python3" <<SHWRAPPER
#!/usr/bin/env bash
if [ "\$1" = - ] && [ "\$#" -eq 5 ] && [ "\$4" = first ]; then
  '$real_python' "\$@" || exit \$?
  for ((n=0; n<100; n++)); do
    if grep -q '__FM_WALK_DISPATCH_EXIT__=0' "\$5" 2>/dev/null; then break; fi
    sleep 0.05
  done
  kill -TERM "\$PPID"
  exit 0
fi
exec '$real_python' "\$@"
SHWRAPPER
  chmod +x "$fakebin/python3"
  local rc=0
  run_check "$parent" PATH="$fakebin:$PATH" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null 2>&1 || rc=$?
  expect_code 143 "$rc" "the sweep must stop after its first launch"
  wait_for "$parent/state/walk-requests/$corr.first.log" '__FM_WALK_DISPATCH_EXIT__=0' || fail "the spawned walk must finish independently"
  snapshot="$parent/data/walk-requests/$corr/brief.md"
  rm "$snapshot" "$mate/data/walk-briefs/brief.md"
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" > "$parent/wakes"
  assert_grep 'first walk complete' "$send.calls" "the already-spawned result must survive sibling refusal"
  for out in second third; do
    assert_grep "walk $out@" "$send.calls" "each unstarted sibling must receive its own refusal"
  done
  [ "$(wc -l < "$dispatch.calls")" -eq 1 ] || fail "only the spawned walk may reach the dispatcher"
  [ "$(wc -l < "$send.calls")" -eq 3 ] || fail "all three per-walk results must return"
  ! grep -q 'nothing dispatched' "$parent/wakes" "$send.calls" || fail "partial dispatch must never be described as nothing dispatched"
  rec="$parent/state/walk-requests/$corr.record"
  grep -Fxq phase=delivered "$rec" || fail "the mixed request must complete after every outcome returns"
  pass "walk-request: a resumed partial launch refuses only its unstarted remainder and delivers prior results"
}

test_interrupted_launch_does_not_consume_recovery() {
  local parent mate dispatch send fakebin real_python out corr rec log rc n
  parent=$(make_parent retry-commit-main)
  mate=$(make_mate retry-commit-mate "$parent")
  dispatch="$parent/fake-dispatch"
  send="$parent/fake-send"
  fake_dispatcher "$dispatch"
  fake_send "$send"
  out=$(run_carrier "$mate" --brief "$mate/data/walk-briefs/brief.md" --release "$RELEASE" --walks step --bot Walker)
  corr=$(printf '%s\n' "$out" | sed -n 's/^corr=//p')
  rec="$parent/state/walk-requests/$corr.record"
  log="$parent/state/walk-requests/$corr.step.log"
  fakebin="$parent/path"
  mkdir -p "$fakebin"
  real_python=$(command -v python3)
  cat > "$fakebin/python3" <<SHWRAPPER
#!/usr/bin/env bash
if [ "\$1" = - ] && [ "\$#" -eq 5 ]; then
  kill -TERM "\$PPID"
  exit 0
fi
exec '$real_python' "\$@"
SHWRAPPER
  chmod +x "$fakebin/python3"
  for n in 1 2 3; do
    rc=0
    run_check "$parent" PATH="$fakebin:$PATH" FM_WALK_REQUEST_DISPATCH="$dispatch" \
      FM_WALK_REQUEST_SEND="$send" FM_WALK_REQUEST_NOW=4102444800 >/dev/null 2>&1 || rc=$?
    expect_code 143 "$rc" "interruption before initial or recovery launch must leave the request pending"
    grep -Fxq retried= "$rec" || fail "an unacknowledged launch must not consume recovery"
    grep -Fxq phase=dispatching "$rec" || fail "an interrupted launch must not finish the request"
    [ ! -e "$dispatch.calls" ] || fail "the interrupted launcher must not dispatch"
    [ ! -e "$send.calls" ] || fail "an unattempted recovery must not return a false failure"
    if [ "$n" -eq 1 ]; then printf 'preserved report bytes\n' >> "$log"; fi
  done
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" \
    FM_WALK_REQUEST_NOW=4102444800 >/dev/null
  grep -Fxq retried=step "$rec" || fail "acknowledging the launcher must consume its recovery attempt"
  wait_for "$log" '__FM_WALK_DISPATCH_EXIT__=0' || fail "recovery must still run after interrupted launches"
  run_check "$parent" FM_WALK_REQUEST_DISPATCH="$dispatch" FM_WALK_REQUEST_SEND="$send" >/dev/null
  assert_grep 'preserved report bytes' "$send.calls" "recovery must preserve previous report bytes"
  assert_grep 'walk green: every step passed' "$send.calls" "the eventual dispatch result must return"
  [ "$(wc -l < "$dispatch.calls")" -eq 1 ] || fail "only the acknowledged launch must dispatch"
  [ "$(wc -l < "$send.calls")" -eq 1 ] || fail "only the real result must be delivered"
  grep -Fxq phase=delivered "$rec" || fail "the acknowledged recovery must complete the request"
  pass "walk-request: interrupted initial and recovery launches leave recovery available until acknowledged"
}

test_interrupted_launch_does_not_consume_recovery

test_inline_remote_briefs_and_size_limits
test_launch_refreshes_stale_attempt_without_losing_output
test_partial_launch_refuses_only_unstarted_walks
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
test_launch_progress_survives_interruption
test_launch_is_portable_and_failures_return
test_slow_deliveries_are_bounded_and_fair
test_brief_disclosure_boundaries
test_complete_reports_survive_recovery_and_return_with_pointers
test_historical_discovery_reserves_processing_and_advances

echo "# fm-walk-request.test.sh: all assertions passed"
