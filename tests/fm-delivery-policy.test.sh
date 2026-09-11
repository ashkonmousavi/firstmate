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
  assert_grep 'Change impact determines required evidence; it does not automatically select a delivery tool or reviewer' "$ROOT/AGENTS.md" \
    "AGENTS.md still conflates substantive impact with an automatic review route"
  assert_grep 'Automatic AI reviewer/fixer routes may run only when the captain explicitly authorizes one for the current work' "$ROOT/AGENTS.md" \
    "AGENTS.md does not preserve the current captain ban on automatic reviewer/fixer routes"
  # shellcheck disable=SC2016 # Markdown backticks are literal source-policy text.
  assert_no_grep 'a change touching a product path, a stated contract, a durable record, safety or merge authority, or a stage gate ships full `no-mistakes`' "$ROOT/AGENTS.md" \
    "AGENTS.md still automatically routes substantive changes to no-mistakes"
  assert_no_grep 'otherwise follow the faster path without adding an independent reviewer' "$ROOT/AGENTS.md" \
    "AGENTS.md still conflicts with informed review on the selected direct-PR route"
  assert_grep 'No automatic AI reviewer/fixer workflow or PR-body attestation is required' "$ROOT/CONTRIBUTING.md" \
    "CONTRIBUTING.md still leaves the obsolete automatic-attestation requirement ambiguous"
  if grep -R -E -n 'require-no-mistakes|no-mistakes-pipeline-attestation|PR must be raised via no-mistakes' \
      "$ROOT/.github/workflows" >/dev/null 2>&1; then
    fail "a GitHub workflow still imposes the removed no-mistakes attestation contract"
  fi
  pass "Firstmate delivery uses direct PR, informed exact-source review, and real CI without an automated attestation workflow"
}

test_direct_pr_informed_review_route_has_no_attestation_workflow
