#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml runs the bounded portable changed-file baseline.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_uses_bounded_changed_file_baseline_without_live_herdr() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts val.nil? ? "" : val
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  [ "$val" = "bin/fm-test-run.sh --changed --exclude-family real-herdr-gated" ] \
    || fail "commands.test must remain the bounded changed-file baseline excluding live Herdr; got: ${val:-<empty>}"
  pass "no-mistakes runs the bounded changed-file baseline and excludes live Herdr"
}

test_nm_uses_bounded_changed_file_baseline_without_live_herdr
