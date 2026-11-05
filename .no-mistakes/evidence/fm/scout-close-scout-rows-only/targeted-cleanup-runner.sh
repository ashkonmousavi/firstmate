#!/usr/bin/env bash
FM_TEST_FIXTURE_IMPORT=teardown
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown.test.sh"
test_scout_phase_cleanup_retains_its_owner_and_dependencies
