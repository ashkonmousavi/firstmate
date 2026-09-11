#!/usr/bin/env bash
# Contract: this fork ships Firstmate source by direct PR, informed independent
# review of the exact code, and real CI; no automated-review attestation workflow
# may silently become mandatory again.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"

test_direct_pr_informed_review_route_has_no_attestation_workflow() {
  [ ! -e "$WORKFLOW" ] \
    || fail "the removed mandatory automated-attestation workflow was restored"
  assert_grep 'selected route is direct-PR with informed independent review of the exact source and real CI' "$ROOT/AGENTS.md" \
    "AGENTS.md does not own the selected Firstmate delivery route"
  assert_grep 'No automatic AI reviewer/fixer workflow or PR-body attestation is required' "$ROOT/CONTRIBUTING.md" \
    "CONTRIBUTING.md still leaves the obsolete automatic-attestation requirement ambiguous"
  if grep -R -E -n 'require-no-mistakes|no-mistakes-pipeline-attestation|PR must be raised via no-mistakes' \
      "$ROOT/.github/workflows" >/dev/null 2>&1; then
    fail "a GitHub workflow still imposes the removed no-mistakes attestation contract"
  fi
  pass "Firstmate delivery uses direct PR, informed exact-source review, and real CI without an automated attestation workflow"
}

test_direct_pr_informed_review_route_has_no_attestation_workflow
