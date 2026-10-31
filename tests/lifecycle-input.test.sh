#!/usr/bin/env bash
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lifecycle-input.sh"

TMP_ROOT=$(fm_test_tmproot lifecycle-input)
log="$TMP_ROOT/input.log"
printf 'key=C-u\nkey=Escape\n' > "$log"
fm_test_lifecycle_input "$log" interrupt || fail "a clear and interrupt must pass"
printf 'key=C-u\ntext=/exit\nkey=enter\n' > "$log"
fm_test_lifecycle_input "$log" exit /exit || fail "a clear followed by an exit command must pass"
printf 'key=Enter\nkey=Escape\n' > "$log"
if fm_test_lifecycle_input "$log" interrupt; then fail "submission followed immediately by cancellation must fail"; fi
printf 'key=enter\nkey=C-u\ntext=/exit\nkey=enter\n' > "$log"
if fm_test_lifecycle_input "$log" exit /exit; then fail "submission before the exit command must fail"; fi
printf 'text=an unread doorbell\nkey=Enter\ntext=/exit\nkey=Enter\n' > "$log"
if fm_test_lifecycle_input "$log" exit /exit; then fail "submission of a doorbell before exit must fail"; fi
: > "$log"
if fm_test_lifecycle_input "$log" interrupt; then fail "an unobserved transport must fail"; fi
pass "lifecycle transport oracle rejects submission even when immediately cancelled"
