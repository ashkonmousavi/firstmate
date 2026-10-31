#!/usr/bin/env bash
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
export FM_TEST_FIXTURE_IMPORT=spawn-quota
# shellcheck source=tests/fm-spawn-dispatch-profile.test.sh
. "$ROOT/tests/fm-spawn-dispatch-profile.test.sh"
unset FM_TEST_FIXTURE_IMPORT

test_quota_gate_refuses_short_and_exhausted_grok_naming_the_best_alternative
test_quota_alternatives_obey_launch_capabilities
test_secondmate_quota_refusal_names_a_supported_alternative
test_quota_gate_passes_healthy_and_long_runway_harnesses
test_quota_gate_unknown_provider_passes_with_notice
test_quota_gate_override_passes_and_is_recorded

id=catalog-native
quota_gate_case "$id" pi "$id" through
jq '(.providers[] | select(.provider == "codex").quotaSemantics.effectiveAvailability) +=
  [{scope:"model:gpt-6-astra", status:"known", effectivePercentRemaining:0,
    runway:{status:"exhausted_now"}, selection:{status:"known",spendPriority:-3}}]' \
  "$CASE_DIR/quota.json" > "$CASE_DIR/native.json"
cat > "$FAKEBIN_DIR/pi" <<'PY'
#!/usr/bin/env python3
import json
import sys
if "--help" in sys.argv:
    print("--tui-mode --approve")
    sys.exit()
if "--mode" not in sys.argv:
    sys.exit()
model = sys.argv[sys.argv.index("--model") + 1] if "--model" in sys.argv else "default"
if model not in ("default", "astra", "codex-native/gpt-6-astra", "glm-5.3"):
    sys.exit(1)
provider, name = ("zai", "glm-5.3") if model == "glm-5.3" else ("codex-native", "gpt-6-astra")
for line in sys.stdin:
    request = json.loads(line)
    if request["type"] != "get_state":
        raise RuntimeError("catalog probe tried to generate a turn")
    print(json.dumps({"id":request["id"],"type":"response","success":True,
                      "data":{"model":{"provider":provider,"id":name}}}), flush=True)
PY
chmod +x "$FAKEBIN_DIR/pi"
for executable in codex grok; do
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN_DIR/$executable"
  chmod +x "$FAKEBIN_DIR/$executable"
done
for selection in codex-native/gpt-6-astra astra default; do
  args=(--harness pi)
  [ "$selection" = default ] || args+=(--model "$selection")
  out=$(FM_QUOTA_MODEL_CATALOG_FILE='' FM_QUOTA_SNAPSHOT_FILE="$CASE_DIR/native.json" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "${args[@]}")
  rc=$?
  expect_code 1 "$rc" "catalog-resolved $selection must refuse exhausted model quota: $out"
  assert_contains "$out" 'provider codex runway exhausted_now at model:gpt-6-astra' "catalog identity must reach quota matching"
  assert_contains "$out" '--harness pi --model zai/glm-5.3' "the named alternative must also resolve through its own catalog"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "catalog refusal published metadata"
done
pass "native Pi catalog resolves explicit models, aliases, and defaults before spawn quota matching"
out=$(FM_QUOTA_MODEL_CATALOG_FILE='' FM_QUOTA_SNAPSHOT_FILE="$CASE_DIR/native.json" \
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness pi --model unresolvable-model)
rc=$?
expect_code 0 "$rc" "an unresolvable model must pass with a notice: $out"
assert_contains "$out" 'catalog could not resolve pi unresolvable-model' "missing catalog resolution was silent"
pass "an unresolvable native model passes with a disclosed uncertainty notice"

cat > "$FAKEBIN_DIR/catalog-vendor" <<'PY'
#!/usr/bin/env python3
import json
import sys
for line in sys.stdin:
    request = json.loads(line)
    method = request["method"]
    if method == "initialized":
        continue
    if method == "initialize":
        result = {}
    elif method == "config/read":
        result = {"config":{"model":"gpt-6-astra","model_provider":"openai"}}
    elif method == "model/list":
        result = {"data":[{"id":"astra","model":"gpt-6-astra","isDefault":True}],"nextCursor":None}
    elif method == "_x.ai/models/list":
        result = {"result":{"currentModelId":"grok-4.7","availableModels":[{"modelId":"grok-4.7"}]}}
    else:
        raise RuntimeError("unexpected vendor operation")
    print(json.dumps({"id":request["id"],"result":result}), flush=True)
PY
chmod +x "$FAKEBIN_DIR/catalog-vendor"
for selection in '' astra gpt-6-astra; do
  out=$(FM_QUOTA_MODEL_CATALOG_FILE='' python3 "$ROOT/bin/fm-harness-model.py" codex "$FAKEBIN_DIR/catalog-vendor" "$selection" "$PROJ_DIR"); rc=$?
  expect_code 0 "$rc" "Codex catalog query should resolve $selection"
  printf '%s\n' "$out" | jq -e '.model == "gpt-6-astra" and .provider == "openai"' >/dev/null \
    || fail "Codex catalog returned the wrong identity: $out"
done
out=$(FM_QUOTA_MODEL_CATALOG_FILE='' python3 "$ROOT/bin/fm-harness-model.py" grok "$FAKEBIN_DIR/catalog-vendor" '' "$PROJ_DIR"); rc=$?
expect_code 0 "$rc" "Grok catalog query should resolve its default"
printf '%s\n' "$out" | jq -e '.model == "grok-4.7"' >/dev/null || fail "Grok catalog returned the wrong identity: $out"
pass "Codex and Grok catalog queries use native non-generating protocol boundaries"

catalog_saved=$FM_QUOTA_MODEL_CATALOG_FILE
id=quota-exclusions
quota_gate_case "$id" pi "$id" through
printf 'hidden_tool\n' > "$HOME_DIR/config/crew-exclude-tools"
printf '%s\n' '{"default":[{"harness":"codex","model":"gpt-6.1-sol"},{"harness":"pi-signed","model":"codex-native/gpt-6-astra"}]}' \
  > "$HOME_DIR/config/crew-dispatch.json"
jq '."pi-signed" += [{id:"codex-native/gpt-6-astra", model:"codex-native/gpt-6-astra", provider:"codex-native"}]' \
  "$catalog_saved" > "$CASE_DIR/catalog.json"
jq '(.providers[] | select(.provider == "zai").quotaSemantics.effectiveAvailability[]) |=
  (.effectivePercentRemaining=0 | .runway.status="exhausted_now")' "$CASE_DIR/quota.json" > "$CASE_DIR/exhausted.json"
out=$(FM_QUOTA_MODEL_CATALOG_FILE="$CASE_DIR/catalog.json" FM_QUOTA_SNAPSHOT_FILE="$CASE_DIR/exhausted.json" \
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness pi --model glm-5.3)
rc=$?
expect_code 1 "$rc" "exhausted Pi must refuse with exclusions: $out"
assert_contains "$out" 'Best alternative: provider codex (spendPriority 0.85): --harness pi-signed --model codex-native/gpt-6-astra.' \
  "tool exclusions must remove higher-ranked unsupported workers"
pass "worker quota alternatives honor tool exclusions"
for kind in ship scout secondmate; do
  out=$(FM_QUOTA_MODEL_CATALOG_FILE="$CASE_DIR/catalog.json" fm_quota_gate_explicit pi glm-5.3 \
    "$HOME_DIR/config/crew-dispatch.json" "$CASE_DIR/exhausted.json" "$kind" tmux "$PROJ_DIR" "$HOME_DIR/config")
  if [ "$kind" = secondmate ]; then
    assert_contains "$out" '--harness codex --model gpt-6.1-sol' "secondmates must remain exempt from worker exclusions"
  else
    assert_not_contains "$out" '--harness codex ' "worker exclusions leaked for $kind"
  fi
done
: > "$HOME_DIR/config/crew-exclude-tools"
out=$(FM_QUOTA_MODEL_CATALOG_FILE="$CASE_DIR/catalog.json" fm_quota_gate_explicit pi glm-5.3 \
  "$HOME_DIR/config/crew-dispatch.json" "$CASE_DIR/exhausted.json" ship tmux "$PROJ_DIR" "$HOME_DIR/config")
assert_contains "$out" '--harness codex --model gpt-6.1-sol' "an empty exclusion list must permit Codex alternatives"
pass "tool exclusions cover ships and scouts, preserve secondmates, and permit empty lists"

export FM_TEST_FIXTURE_IMPORT=control-relaunch
# shellcheck source=tests/fm-control-relaunch.test.sh
. "$ROOT/tests/fm-control-relaunch.test.sh"
unset FM_TEST_FIXTURE_IMPORT
test_quota_gate_refuses_an_explicit_relaunch_before_the_agent_stops
test_secondmate_quota_relaunch_names_a_supported_alternative
test_quota_override_relaunches_and_is_recorded

id=quota-control-catalog
dir=$(quota_relaunch_case quota-control-catalog "$id" through)
jq '.pi = [{id:"codex-native/gpt-6-astra",model:"codex-native/gpt-6-astra",aliases:["astra"],provider:"codex-native",default:true}]' \
  "$catalog_saved" > "$dir/catalog.json"
jq '(.providers[] | select(.provider == "codex").quotaSemantics.effectiveAvailability) +=
  [{scope:"model:gpt-6-astra", status:"known", effectivePercentRemaining:0,
    runway:{status:"exhausted_now"}, selection:{status:"known",spendPriority:-3}}]' \
  "$dir/quota.json" > "$dir/exhausted.json"
for selection in codex-native/gpt-6-astra astra default; do
  out=$(FM_QUOTA_MODEL_CATALOG_FILE="$dir/catalog.json" FM_QUOTA_SNAPSHOT_FILE="$dir/exhausted.json" \
    run_control "$dir" "$id" relaunch --harness pi --model "$selection" --note 'check effective model'); rc=$?
  expect_code 1 "$rc" "relaunch must refuse catalog-resolved $selection: $out"
  assert_contains "$out" 'provider codex runway exhausted_now at model:gpt-6-astra' "relaunch missed catalog model quota"
  [ ! -s "$dir/fake/literal" ] || fail "catalog refusal stopped the old agent"
done
pass "relaunch resolves catalog models, aliases, and defaults before stopping the agent"

id=quota-control-exclusions
dir=$(quota_relaunch_case quota-control-exclusions "$id" through)
printf 'hidden_tool\n' > "$dir/home/config/crew-exclude-tools"
printf '%s\n' '{"default":[{"harness":"codex","model":"gpt-6.1-sol"},{"harness":"pi-signed","model":"codex-native/gpt-6-astra"}]}' \
  > "$dir/home/config/crew-dispatch.json"
jq '."pi-signed" += [{id:"codex-native/gpt-6-astra", model:"codex-native/gpt-6-astra", provider:"codex-native"}]' \
  "$catalog_saved" > "$dir/catalog.json"
jq '(.providers[] | select(.provider == "zai").quotaSemantics.effectiveAvailability[]) |=
  (.effectivePercentRemaining=0 | .runway.status="exhausted_now")' "$dir/quota.json" > "$dir/exhausted.json"
out=$(FM_QUOTA_MODEL_CATALOG_FILE="$dir/catalog.json" FM_QUOTA_SNAPSHOT_FILE="$dir/exhausted.json" \
  run_control "$dir" "$id" relaunch --harness pi --model glm-5.3 --note 'check quota before exit'); rc=$?
expect_code 1 "$rc" "control must refuse the exhausted requested Pi model: $out"
assert_contains "$out" '--harness pi-signed --model codex-native/gpt-6-astra' "control recommended an excluded runtime"
[ ! -s "$dir/fake/literal" ] || fail "control stopped the worker during quota refusal"
pass "relaunch quota alternatives honor worker exclusions before stopping the agent"

id=remote-quota-host
dir=$(new_case remote-quota-host "$id")
add_herdr_ship_task "$dir" "$id" fm-remote
make_herdr_stub "$dir"
rm "$dir/fake/herdr-stopped"
remote_home="$dir/wt"
mkdir -p "$remote_home/bin" "$remote_home/data" "$remote_home/config" "$dir/code"
cp "$ROOT/AGENTS.md" "$remote_home/AGENTS.md"
printf '%s\n' "$id" > "$remote_home/.fm-secondmate-home"
printf 'remote quota test charter\n' > "$remote_home/data/charter.md"
cp -R "$ROOT/bin" "$dir/code/bin"
cp "$ROOT/AGENTS.md" "$dir/code/AGENTS.md"
cp "$dir/home/config/"* "$remote_home/config/"
fm_test_quota_snapshot "$dir/quota.json" exhausted
mv "$dir/fakebin/herdr" "$dir/fakebin/herdr-base"
cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = 'pane read' ]; then
  printf '╭────╮\n│    │\n╰────╯\n'
  exit 0
fi
if [ "${1:-} ${2:-}" = 'pane send-text' ]; then
  case "${4:-}" in
    /quit|/exit)
      rm -f "$FM_FAKE_DIR/herdr-agent-live" "$FM_FAKE_DIR/herdr-agent-registration"
      touch "$FM_FAKE_DIR/plain-shell"
      exit 0 ;;
    *) rm -f "$FM_FAKE_DIR/plain-shell" ;;
  esac
fi
if [ "${1:-} ${2:-}" = 'pane process-info' ] && [ -f "$FM_FAKE_DIR/plain-shell" ]; then
  printf '{"result":{"type":"pane_process_info","process_info":{"shell_pid":4242,"foreground_processes":[]}}}\n'
  exit 0
fi
exec "$(dirname "$0")/herdr-base" "$@"
SH
chmod +x "$dir/fakebin/herdr"
run_host() {
  FM_QUOTA_SNAPSHOT_FILE="$dir/quota.json" run_lifecycle_fixture "$dir" env \
    FM_ROOT_OVERRIDE="$dir/code" FM_HOME="$remote_home" \
    "$dir/code/bin/fm-remote-secondmate-control.sh" "$@"
}
host_meta="$remote_home/state/parent-route/$id.meta"
out=$(run_host launch "$id" grok - - herdr); rc=$?
expect_code 1 "$rc" "host launch must refuse exhausted Grok: $out"
[ ! -e "$host_meta" ] || fail "refused remote launch created task metadata"
out=$(run_host launch "$id" grok - - herdr --quota-override 'remote launch override'); rc=$?
expect_code 0 "$rc" "host launch must honor the explicit override: $out"
grep -Fxq 'quota_override=remote launch override' "$host_meta" || fail "host lost launch override"
assert_grep 'quota_override_evidence=refuse: provider grok' "$host_meta" "host lost launch refusal evidence"
cp "$host_meta" "$dir/before-relaunch.meta"
out=$(run_host relaunch "$id" grok - -); rc=$?
expect_code 1 "$rc" "host relaunch must refuse exhausted Grok without an override: $out"
cmp -s "$host_meta" "$dir/before-relaunch.meta" || fail "refusal changed remote metadata"
out=$(run_host relaunch "$id" grok - - --quota-override 'remote relaunch override'); rc=$?
expect_code 0 "$rc" "host relaunch must honor the explicit override: $out"
grep -Fxq 'quota_override=remote relaunch override' "$host_meta" || fail "host lost relaunch override"
assert_contains "$out" 'quota_override_evidence=refuse: provider grok' "route confirmation lost host evidence"
pass "remote host launch and relaunch refuse exhausted quota unless an explicit recorded override is forwarded"
