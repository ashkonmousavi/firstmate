#!/usr/bin/env bash
set -eu
source tests/lib.sh
source .no-mistakes/runtime/tests/rex-test-safety.sh
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "$*"; }
trap rex_test_cleanup EXIT
rex_test_prepare
pair=$(rex_test_new_session proof)
read -r sid bid <<< "$pair"
target=$(fm_backend_rex_target "$sid" "$bid")
endpoint=$(fm_backend_rex_server_endpoint)
meta="$REX_TEST_WORK/home/state/proof.meta"
printf 'backend=rex\nwindow=%s\nrex_server=%s\n' "$target" "$endpoint" > "$meta"
if fm_task_record_endpoint_confirmed_gone "$meta"; then fail 'a present endpoint was declared absent'; fi
printf 'present endpoint: metadata-aware gone proof refused\n'
fm_backend_rex_kill "$target"
fm_task_record_endpoint_confirmed_gone "$meta" || fail 'recorded-server absence proof refused a killed endpoint'
printf 'killed endpoint: metadata-aware gone proof accepted\n'
if fm_backend_endpoint_confirmed_gone rex "$target"; then fail 'target-only Rex proof accepted'; fi
printf 'killed endpoint: target-only gone proof refused\n'
printf 'backend=rex\nwindow=%s\nrex_server=unix:///not-this-server.sock\n' "$target" > "$meta"
if fm_task_record_endpoint_confirmed_gone "$meta"; then fail 'wrong server accepted'; fi
printf 'killed endpoint: mismatched recorded-server proof refused\n'
printf 'backend=rex\nwindow=%s\n' "$target" > "$meta"
if fm_task_record_endpoint_confirmed_gone "$meta"; then fail 'missing server accepted'; fi
printf 'killed endpoint: missing recorded-server proof refused\n'
rex_test_assert_isolated
