#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-catalog-live-gate)
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/pi" <<'PY'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
if "--version" in sys.argv:
    print("Pi guard-fixture 1")
    sys.exit()
root = Path(os.environ["PI_CODING_AGENT_DIR"])
settings = json.loads((root / "settings.json").read_text())
provider = settings["defaultProvider"]
model = settings["defaultModel"]
assert provider in json.loads((root / "models.json").read_text())["providers"]
for line in sys.stdin:
    request = json.loads(line)
    assert request["type"] == "get_state"
    with open(os.environ["GUARD_CALLS"], "a") as handle:
        handle.write("native state query\n")
    if os.environ.get("GUARD_WRONG"):
        model = "wrong-model"
    print(json.dumps({"id":request["id"],"success":True,"data":{"model":{"id":model,"provider":provider}}}), flush=True)
PY
chmod +x "$TMP_ROOT/bin/pi"
set +e
out=$(env -u FM_LIVE -u FM_QUOTA_CATALOG_LIVE_E2E -u FM_QUOTA_CATALOG_LIVE_CASES \
  PATH="$TMP_ROOT/bin:/usr/bin:/bin" GUARD_CALLS="$TMP_ROOT/calls" \
  bash "$ROOT/tests/fm-quota-catalog-live-e2e.test.sh" 2>&1)
rc=$?
set -e
expect_code 0 "$rc" "the token-free guard must run by default with independent native Pi cases: $out"
[ "$(wc -l < "$TMP_ROOT/calls" | tr -d ' ')" = 2 ] || fail "default guard did not query both explicit and default Pi models"
assert_contains "$out" '2 native catalog cases checked' "guard skipped instead of exercising its native cases"
set +e
out=$(env -u FM_LIVE -u FM_QUOTA_CATALOG_LIVE_E2E -u FM_QUOTA_CATALOG_LIVE_CASES \
  PATH="$TMP_ROOT/bin:/usr/bin:/bin" GUARD_CALLS="$TMP_ROOT/calls" GUARD_WRONG=1 \
  bash "$ROOT/tests/fm-quota-catalog-live-e2e.test.sh" 2>&1)
rc=$?
set -e
[ "$rc" != 0 ] || fail "native guard accepted a model inconsistent with its independent configuration"
assert_contains "$out" 'Pi guard-fixture 1' "mismatch omitted the harness version"
pass "token-free catalog guard runs by default, provisions native expectations, and rejects incorrect model state"
