#!/usr/bin/env bash
set -eu
source tests/lib.sh
source .no-mistakes/runtime/tests/rex-test-safety.sh
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "$*"; }
trap rex_test_cleanup EXIT
rex_test_prepare
pair=$(rex_test_new_session restart)
read -r sid bid <<< "$pair"
target=$(fm_backend_rex_target "$sid" "$bid")
endpoint=$(fm_backend_rex_server_endpoint)
meta="$REX_TEST_WORK/home/state/restart.meta"
printf 'backend=rex\nwindow=%s\nrex_server=%s\n' "$target" "$endpoint" > "$meta"
rex_test_stop_server
if fm_task_record_endpoint_confirmed_gone "$meta"; then fail 'stopped server was accepted as proof of absence'; fi
printf 'Stopped private server: metadata-aware absence proof refused\n'
rex_test_start_server
printf 'Native block size after restarting with retained state: '
rex_test_cli block call -s "$sid" -b "$bid" size
printf '\nAdapter state after restart: %s\n' "$(fm_backend_rex_endpoint_absence_recheck "$target" "$endpoint")"
if fm_task_record_endpoint_confirmed_gone "$meta"; then fail 'retained block was accepted as absent'; fi
printf 'Persisted native block: metadata-aware absence proof refused\n'
rex_test_cli kill "$sid"
fm_task_record_endpoint_confirmed_gone "$meta" || fail 'explicitly deleted session was not proven gone'
printf 'Explicitly deleted session: metadata-aware absence proof accepted\n'
