#!/usr/bin/env bash
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
export FM_TEST_FIXTURE_IMPORT=spawn-quota
# shellcheck source=tests/fm-spawn-dispatch-profile.test.sh
. "$ROOT/tests/fm-spawn-dispatch-profile.test.sh"
unset FM_TEST_FIXTURE_IMPORT
id=quota-native-record
quota_gate_case "$id" gemini "$id" through
cat > "$FAKEBIN_DIR/gemini" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys
for line in sys.stdin:
    request = json.loads(line)
    if request["method"] == "initialize":
        result = {}
    elif request["method"] == "session/new":
        model = "project-model" if os.environ.get("GEMINI_CLI_TRUST_WORKSPACE") == "true" else "user-model"
        result = {"models":{"currentModelId":model,"availableModels":[{"modelId":model,"providerId":"gemini"}]}}
    else:
        raise AssertionError("probe generated a turn")
    print(json.dumps({"id":request["id"],"result":result}), flush=True)
PY
cat > "$FAKEBIN_DIR/kimi" <<'PY'
#!/usr/bin/env python3
import json
import sys
if sys.argv[1:4] == ["provider", "list", "--json"]:
    print(json.dumps({"models":{"kimi-code/k3":{"model":"k3","provider":"kimi"}}}))
    sys.exit()
for line in sys.stdin:
    request = json.loads(line)
    result = {} if request["method"] == "initialize" else {
        "models":{"currentModelId":"kimi-code/k3","availableModels":[{"modelId":"kimi-code/k3"}]}}
    print(json.dumps({"id":request["id"],"result":result}), flush=True)
PY
chmod +x "$FAKEBIN_DIR/gemini" "$FAKEBIN_DIR/kimi"
printf '%s\n' '{"default":[{"harness":"gemini"},{"harness":"kimi","model":"kimi-code/k3"}]}' > "$HOME_DIR/config/crew-dispatch.json"
jq '.providers += [
  {provider:"gemini",quotaSemantics:{status:"known",effectiveAvailability:[
    {scope:"all_models",status:"known",effectivePercentRemaining:80,runway:{status:"through_reset"},selection:{spendPriority:1}},
    {scope:"model:project-model",status:"known",effectivePercentRemaining:0,runway:{status:"exhausted_now"},selection:{spendPriority:-5}}]}},
  {provider:"kimi",quotaSemantics:{status:"known",effectiveAvailability:[
    {scope:"model:k3",status:"known",effectivePercentRemaining:80,runway:{status:"through_reset"},selection:{spendPriority:10}}]}}
  ]' "$CASE_DIR/quota.json" > "$CASE_DIR/native.json"
out=$(FM_QUOTA_MODEL_CATALOG_FILE='' FM_QUOTA_SNAPSHOT_FILE="$CASE_DIR/native.json" \
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness gemini); rc=$?
expect_code 1 "$rc" "Gemini must gate the trusted project model: $out"
assert_contains "$out" 'provider gemini runway exhausted_now at model:project-model' "Gemini probe omitted launch trust"
assert_contains "$out" '--harness kimi --model kimi-code/k3' "Kimi suggestion replaced its configured selector with an upstream ID"
assert_not_contains "$out" '--harness kimi --model k3' "Kimi suggestion cannot be launched"
[ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused Gemini task published metadata"
jq '(.providers[] | select(.provider=="gemini").quotaSemantics.effectiveAvailability[] | select(.scope=="model:project-model")) |=
  (.effectivePercentRemaining=80 | .runway.status="through_reset" | .selection.spendPriority=1)' "$CASE_DIR/native.json" > "$CASE_DIR/healthy.json"
out=$(FM_QUOTA_MODEL_CATALOG_FILE='' FM_QUOTA_SNAPSHOT_FILE="$CASE_DIR/healthy.json" \
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness gemini); rc=$?
expect_code 0 "$rc" "healthy trusted Gemini must launch from its checked record: $out"
launch=$(cat "$LAUNCH_LOG")
assert_contains "$launch" "--model 'project-model'" "worker dropped the checked launch selector"
assert_contains "$launch" 'GEMINI_CLI_TRUST_WORKSPACE=true' "worker dropped the checked trust environment"
assert_contains "$launch" "GEMINI_CLI_SYSTEM_SETTINGS_PATH=$HOME_DIR/state/$id.gemini-settings.json" "worker did not use the probe's system-settings path"
pass "spawn uses trusted Gemini identity and recommends the selectable Kimi alias"
GEMINI_RECORD_BIN=$FAKEBIN_DIR/gemini
KIMI_RECORD_BIN=$FAKEBIN_DIR/kimi
RECORD_QUOTA=$CASE_DIR/native.json
export FM_TEST_FIXTURE_IMPORT=control-relaunch
# shellcheck source=tests/fm-control-relaunch.test.sh
. "$ROOT/tests/fm-control-relaunch.test.sh"
unset FM_TEST_FIXTURE_IMPORT
id=quota-native-record-control
dir=$(new_case "$id" "$id")
add_ship_task "$dir" "$id" claude
cp "$GEMINI_RECORD_BIN" "$dir/fakebin/gemini"
cp "$KIMI_RECORD_BIN" "$dir/fakebin/kimi"
printf '%s\n' '{"default":[{"harness":"gemini"},{"harness":"kimi","model":"kimi-code/k3"}]}' > "$dir/home/config/crew-dispatch.json"
out=$(FM_QUOTA_MODEL_CATALOG_FILE='' FM_QUOTA_SNAPSHOT_FILE="$RECORD_QUOTA" \
  run_control "$dir" "$id" relaunch --harness gemini --note 'check native launch record'); rc=$?
expect_code 1 "$rc" "control must gate trusted project settings before stopping the old agent: $out"
assert_contains "$out" 'provider gemini runway exhausted_now at model:project-model' "control omitted shared Gemini trust context"
assert_contains "$out" '--harness kimi --model kimi-code/k3' "control lost the Kimi launch selector"
[ ! -s "$dir/fake/literal" ] || fail "control stopped the old agent before native quota refusal"
pass "control consumes the same native context and selector record before stopping the agent"
