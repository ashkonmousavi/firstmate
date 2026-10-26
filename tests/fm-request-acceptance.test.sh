#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v python3 >/dev/null 2>&1 || fail "python3 is required for native request acceptance tests"
command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is required for native request acceptance tests"
python3 -B "$ROOT/tests/test_request_acceptance.py" || fail "native request acceptance tests failed"
pass "native owner-request custody, corrections and confirmed no-write replay"
