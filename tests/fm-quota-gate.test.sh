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
test_quota_gate_unknown_provider_and_missing_reading_notices
test_quota_gate_override_passes_and_is_recorded

test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_claude_haiku_launch_gets_an_opus_advisor
test_batch_forwards_shared_profile_flags

for batch_kind in ship scout; do
  for batch_case in refuse override notice; do
    batch_name="quota-batch-$batch_kind-$batch_case"
    id1="$batch_name-a" id2="$batch_name-b"
    rec=$(make_spawn_case "$batch_name" grok "$id1" "$id2")
    read_case_record "$rec"
    enable_quota_profiles "$HOME_DIR"
    fm_fake_exit0 "$FAKEBIN_DIR" grok
    fm_test_quota_snapshot "$CASE_DIR/quota.json" exhausted
    batch_snapshot="$CASE_DIR/quota.json"
    batch_args=("$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness grok --model grok-4.7)
    batch_runner=run_ship_spawn
    if [ "$batch_kind" = scout ]; then batch_args+=(--scout); batch_runner=run_spawn; fi
    if [ "$batch_case" = override ]; then batch_args+=(--quota-override 'batch review override with spaces'); fi
    [ "$batch_case" != notice ] || batch_snapshot="$CASE_DIR/unavailable.json"
    out=$(FM_QUOTA_SNAPSHOT_FILE="$batch_snapshot" "$batch_runner" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "${batch_args[@]}"); rc=$?
    if [ "$batch_case" = refuse ]; then
      expect_code 1 "$rc" "batch refusal must survive delegation: $out"
      [ "$(printf '%s\n' "$out" | grep -c 'refuses explicit harness grok')" = 2 ] || fail "batch lost a child refusal: $out"
      for id in "$id1" "$id2"; do [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused batch child published metadata"; done
    else
      expect_code 0 "$rc" "batch $batch_case must reach both children: $out"
      for id in "$id1" "$id2"; do
        assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4.7 default
        if [ "$batch_case" = override ]; then
          grep -Fxq 'quota_override=batch review override with spaces' "$HOME_DIR/state/$id.meta" || fail "batch changed the override reason"
          assert_grep 'quota_override_evidence=refuse: provider grok' "$HOME_DIR/state/$id.meta" "batch lost refusal evidence"
        else
          assert_no_grep 'quota_override=' "$HOME_DIR/state/$id.meta" "uncertain batch invented an override"
        fi
      done
      if [ "$batch_case" = override ]; then
        [ "$(printf '%s\n' "$out" | grep -c '^notice: fm-spawn quota check refuses grok')" = 2 ] || fail "batch lost override diagnostics: $out"
      else
        [ "$(printf '%s\n' "$out" | grep -c '^notice: fm-spawn launches grok without the quota check:')" = 2 ] || fail "batch lost uncertainty diagnostics: $out"
      fi
    fi
  done
  pass "$batch_kind batch forwards explicit overrides, evidence, refusals and notices to every pair"
done
rm "$HOME_DIR/config/crew-dispatch.json"
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
  "implicit-batch-a=$PROJ_DIR" "implicit-batch-b=$PROJ_DIR" --scout --quota-override 'not explicit'); rc=$?
expect_code 1 "$rc" "batch override must require a shared explicit harness: $out"
assert_contains "$out" 'applies only to an explicitly named adapter' "implicit batch override was not rejected"
[ ! -e "$HOME_DIR/state/implicit-batch-a.meta" ] && [ ! -e "$HOME_DIR/state/implicit-batch-b.meta" ] || fail "implicit batch override dispatched children"

quota_harness_profiles=(
  'claude|sonnet' 'codex|gpt-6.1-sol' 'opencode|anthropic/claude-sonnet-4-5'
  'pi|zai/glm-5.3' 'pi-signed|codex-native/gpt-6-astra' 'grok|grok-4.7'
  'kimi|kimi-code/k3' 'cursor|cursor-grok-4.5-high' 'omp|openai-codex/gpt-6.1-sol'
  'agy|gemini-3.8-flash-low' 'gemini|gemini-3.1-pro' 'muse|muse-spark-1.2'
  'rovo|auto' 'devin|fusion-claude-fable-5-1-high-sidekick-swe-2-medium'
  'commandcode|deepseek/deepseek-v4.1-flash' 'polytoken|zai/glm-5.3-flash'
)
for quota_profile in "${quota_harness_profiles[@]}"; do
  IFS='|' read -r quota_harness quota_model <<< "$quota_profile"
  for quota_axis in caller configured; do
    [ "$quota_harness:$quota_axis" != polytoken:configured ] || continue
    id="quota-spawn-$quota_harness-$quota_axis"
    quota_gate_case "$id" "$quota_harness" "$id" through
    quota_alternative=codex
    [ "$quota_harness" != codex ] || quota_alternative=claude
    jq -n --arg h "$quota_harness" --arg m "$quota_model" --arg alt "$quota_alternative" \
      '{default:[{harness:$h,model:$m,provider:"blocked"},{harness:$alt,model:"healthy-alternative"}]}' \
      > "$HOME_DIR/config/crew-dispatch.json"
    jq '.providers += [{provider:"blocked",quotaSemantics:{status:"known",effectiveAvailability:[
      {scope:"all_models",status:"known",effectivePercentRemaining:0,runway:{status:"exhausted_now"},selection:{spendPriority:-10}}]}}]' \
      "$CASE_DIR/quota.json" > "$CASE_DIR/all-models.json"
    quota_args=(--harness "$quota_harness")
    [ "$quota_axis" != caller ] || quota_args+=(--model "$quota_model")
    [ "$quota_harness" != polytoken ] || quota_args+=(--effort low)
    out=$(FM_QUOTA_SNAPSHOT_FILE="$CASE_DIR/all-models.json" \
      run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "${quota_args[@]}"); rc=$?
    expect_code 1 "$rc" "$quota_harness/$quota_axis must refuse exhausted spawn quota: $out"
    assert_contains "$out" 'provider blocked runway exhausted_now at all_models' "$quota_harness was not evaluated against its declared quota family"
    assert_contains "$out" "--harness $quota_alternative --model healthy-alternative" "$quota_harness lost its configured alternative"
    assert_not_contains "$out" 'unresolvable' "$quota_harness was incorrectly treated as unresolvable"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "$quota_harness published metadata after quota refusal"
    [ ! -s "$LAUNCH_LOG" ] || fail "$quota_harness launched after quota refusal"
  done
  pass "explicit $quota_harness spawn refuses exhausted model quota"
done

inputs="$TMP_ROOT/quota-model-inputs"
mkdir -p "$inputs/bin"
fm_test_quota_snapshot "$inputs/quota.json" through
jq '(.providers[] | select(.provider=="codex").quotaSemantics.effectiveAvailability) +=
  [{scope:"model:configured-model",status:"known",effectivePercentRemaining:0,runway:{status:"exhausted_now"},selection:{spendPriority:-1}}]' \
  "$inputs/quota.json" > "$inputs/model.json"
printf '%s\n' '{"default":[{"harness":"codex","model":"configured-model"},{"harness":"kimi","model":"kimi-code/k3","provider":"codex","effort":"high"}]}' > "$inputs/rules.json"
for harness in claude codex opencode pi pi-signed grok kimi cursor cursor-agent omp agy gemini muse rovo devin commandcode polytoken; do
  cat > "$inputs/bin/$harness" <<'PROBE'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "$QUOTA_PROBE_LOG"
exit 75
PROBE
  chmod +x "$inputs/bin/$harness"
done
out=$(PATH="$inputs/bin:$PATH" QUOTA_PROBE_LOG="$inputs/probes" \
  fm_quota_gate_explicit codex '' "$inputs/rules.json" "$inputs/model.json" ship tmux "$inputs"); rc=$?
expect_code 1 "$rc" "configured model quota must apply when no caller model is supplied: $out"
assert_contains "$out" 'exhausted_now at model:configured-model' "the configured model was not checked literally"
assert_contains "$out" '--harness kimi --model kimi-code/k3 --effort high' "configured suggestion strings changed"
out=$(PATH="$inputs/bin:$PATH" QUOTA_PROBE_LOG="$inputs/probes" \
  fm_quota_gate_explicit codex caller-model "$inputs/rules.json" "$inputs/model.json" ship tmux "$inputs"); rc=$?
expect_code 0 "$rc" "caller model must take precedence over the configured model: $out"
[ "$(printf '%s\n' "$out" | head -1)" = pass ] || fail "caller model did not pass: $out"
out=$(PATH="$inputs/bin:$PATH" QUOTA_PROBE_LOG="$inputs/probes" \
  fm_quota_gate_explicit codex '' "$inputs/missing.json" "$inputs/model.json" ship tmux "$inputs"); rc=$?
expect_code 0 "$rc" "a missing model must use harness-level quota only: $out"
[ "$(printf '%s\n' "$out" | sed -n 3p)" = none ] || fail "an unconfigured alternative was invented: $out"
[ ! -e "$inputs/probes" ] || fail "quota evaluation invoked a native harness: $(cat "$inputs/probes")"
pass "caller, configured, and harness-level identities need no native executable and suggestions preserve configured strings"

id=quota-default-unchanged
quota_gate_case "$id" codex "$id" through
printf '%s\n' '{"default":{"harness":"codex","model":"configured-model"}}' > "$HOME_DIR/config/crew-dispatch.json"
out=$(FM_QUOTA_SNAPSHOT_FILE="$CASE_DIR/quota.json" \
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness codex); rc=$?
expect_code 0 "$rc" "a healthy explicit harness must retain its ordinary default launch: $out"
assert_not_contains "$(cat "$LAUNCH_LOG")" '--model ' "quota checking forced a model the caller never supplied"
pass "quota checking leaves the worker default model selection unchanged"

id=quota-configured-account
quota_gate_case "$id" pi "$id" through
printf '%s\n' '{"default":[{"harness":"pi","model":"openai-codex-work/gpt-6-astra","provider":"codex"},{"harness":"claude","model":"sonnet"}]}' \
  > "$HOME_DIR/config/crew-dispatch.json"
jq '.schemaVersion=6 | .providers |= map(. + {accountKey:"default"}) |
  .providers += [.providers[] | select(.provider=="codex") | .accountKey="openai-codex-work" |
    .quotaSemantics.effectiveAvailability[] |= (.effectivePercentRemaining=0 | .runway.status="exhausted_now")]' \
  "$CASE_DIR/quota.json" > "$CASE_DIR/accounts.json"
out=$(FM_QUOTA_SNAPSHOT_FILE="$CASE_DIR/accounts.json" \
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --harness pi --model openai-codex-work/gpt-6-astra); rc=$?
expect_code 1 "$rc" "the configured account must retain its codex quota family: $out"
assert_contains "$out" 'provider codex runway exhausted_now' "the account replaced the quota family"
assert_contains "$out" '--harness claude --model sonnet' "recommendation must retain the configured model string"
[ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the exhausted account launched"
pass "configured account IDs join their quota family without borrowing a healthy default account"

id=quota-exclusions
quota_gate_case "$id" pi "$id" through
printf 'hidden_tool\n' > "$HOME_DIR/config/crew-exclude-tools"
printf '%s\n' '{"default":[{"harness":"pi","model":"glm-5.3","provider":"zai"},{"harness":"codex","model":"gpt-6.1-sol"},{"harness":"pi-signed","model":"codex-native/gpt-6-astra","provider":"codex"}]}' \
  > "$HOME_DIR/config/crew-dispatch.json"
jq '(.providers[] | select(.provider == "zai").quotaSemantics.effectiveAvailability[]) |=
  (.effectivePercentRemaining=0 | .runway.status="exhausted_now")' "$CASE_DIR/quota.json" > "$CASE_DIR/exhausted.json"
out=$(FM_QUOTA_SNAPSHOT_FILE="$CASE_DIR/exhausted.json" \
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness pi --model glm-5.3)
rc=$?
expect_code 1 "$rc" "exhausted Pi must refuse with exclusions: $out"
assert_contains "$out" 'Best alternative: provider codex (spendPriority 0.85): --harness pi-signed --model codex-native/gpt-6-astra.' \
  "tool exclusions must remove higher-ranked unsupported workers"
pass "worker quota alternatives honor tool exclusions"
for kind in ship scout secondmate; do
  out=$(fm_quota_gate_explicit pi glm-5.3 \
    "$HOME_DIR/config/crew-dispatch.json" "$CASE_DIR/exhausted.json" "$kind" tmux "$HOME_DIR/config")
  if [ "$kind" = secondmate ]; then
    assert_contains "$out" '--harness codex --model gpt-6.1-sol' "secondmates must remain exempt from worker exclusions"
  else
    assert_not_contains "$out" '--harness codex ' "worker exclusions leaked for $kind"
  fi
done
: > "$HOME_DIR/config/crew-exclude-tools"
out=$(fm_quota_gate_explicit pi glm-5.3 \
  "$HOME_DIR/config/crew-dispatch.json" "$CASE_DIR/exhausted.json" ship tmux "$HOME_DIR/config")
assert_contains "$out" '--harness codex --model gpt-6.1-sol' "an empty exclusion list must permit Codex alternatives"
pass "tool exclusions cover ships and scouts, preserve secondmates, and permit empty lists"

id=quota-account-eligibility
quota_gate_case "$id" grok "$id" exhausted
mkdir -p "$CASE_DIR/pi-root" "$HOME_DIR/config/secondmate-accounts/pinned-mate"
printf '%s\ncodex-native\n' "$CASE_DIR/pi-root" > "$HOME_DIR/config/pi-account"
printf '%s\nzai\n' "$CASE_DIR/pi-root" > "$HOME_DIR/config/secondmate-accounts/pinned-mate/pi-account"
printf '%s\n' '{"default":[{"harness":"pi","model":"zai/glm-5.3","provider":"zai"},{"harness":"pi","model":"codex-native/gpt-6-astra","provider":"codex"}]}' \
  > "$HOME_DIR/config/crew-dispatch.json"
jq '(.providers[] | select(.provider=="zai").quotaSemantics.effectiveAvailability[].selection.spendPriority)=9' \
  "$CASE_DIR/quota.json" > "$CASE_DIR/ranked.json"
for kind in ship scout secondmate; do
  mate=
  [ "$kind" != secondmate ] || mate=pinned-mate
  out=$(fm_quota_gate_explicit grok '' "$HOME_DIR/config/crew-dispatch.json" "$CASE_DIR/ranked.json" \
      "$kind" tmux "$HOME_DIR/config" "$mate")
  rc=$?
  expect_code 1 "$rc" "exhausted Grok must refuse before account ranking"
  if [ "$kind" = secondmate ]; then
    assert_contains "$out" '--harness pi --model zai/glm-5.3' "secondmate-specific provider pin was ignored"
    assert_not_contains "$out" '--model codex-native/' "parent account pin overrode the mate pin"
  else
    assert_contains "$out" '--harness pi --model codex-native/gpt-6-astra' "a disallowed provider survived ranking"
    assert_not_contains "$out" '--model zai/' "retained Zai credentials bypassed the provider restriction"
  fi
done
pass "quota alternatives honor permitted providers and per-secondmate account precedence"

id=quota-route-alternatives
quota_gate_case "$id" grok "$id" exhausted
printf '%s\n' '{"default":[{"harness":"omp","model":"openai-codex/gpt-6.1-sol","provider":"omp-quota"},{"harness":"codex","model":"gpt-6.1-sol"}]}' > "$CASE_DIR/route-rules.json"
jq '.providers += [{provider:"omp-quota",quotaSemantics:{status:"known",effectiveAvailability:[
  {scope:"all_models",status:"known",effectivePercentRemaining:90,runway:{status:"through_reset"},selection:{spendPriority:9}}]}}]' \
  "$CASE_DIR/quota.json" > "$CASE_DIR/route-quota.json"
for route_flags in 0:0 1:0 0:1 1:1; do
  sync_flag=${route_flags%:*} inherit_flag=${route_flags#*:}
  out=$(FM_SKIP_SECONDMATE_SYNC="$sync_flag" FM_SKIP_SECONDMATE_INHERIT="$inherit_flag" \
    fm_quota_gate_explicit grok '' "$CASE_DIR/route-rules.json" "$CASE_DIR/route-quota.json" secondmate herdr "$HOME_DIR/config"); rc=$?
  expect_code 1 "$rc" "exhausted Grok must refuse before route ranking: $out"
  if [ "$route_flags" = 1:1 ]; then
    assert_contains "$out" '--harness codex --model gpt-6.1-sol' "remote route did not select its eligible alternative"
    assert_not_contains "$out" '--harness omp' "remote route recommended unsupported OMP"
  else
    assert_contains "$out" '--harness omp --model openai-codex/gpt-6.1-sol' "local OMP eligibility was lost"
  fi
done
pass "remote alternative ranking excludes OMP while local secondmates retain it"

id=quota-capture-eligibility
quota_gate_case "$id" grok "$id" exhausted
for h in kimi codex; do
  printf '{"default":[{"harness":"%s","provider":"codex","model":"configured-selection","effort":"high"},{"harness":"claude"}]}\n' "$h" > "$CASE_DIR/rules.json"
  for backend in tmux herdr zellij cmux orca paseo; do
    for typed in 0 1; do
      out=$(FM_CODEX_TYPED_LAUNCH="$typed" \
        fm_quota_gate_explicit grok '' "$CASE_DIR/rules.json" "$CASE_DIR/quota.json" ship "$backend" "$HOME_DIR/config")
      if { [ "$h" = kimi ] || [ "$typed" = 1 ]; } && { [ "$backend" = cmux ] || [ "$backend" = orca ] || [ "$backend" = paseo ]; }; then
        assert_contains "$out" '--harness claude' "an unsupported capture backend survived ranking"
      else
        assert_contains "$out" "--harness $h " "a supported capture path was excluded"
        assert_contains "$out" '--effort high' "suggestion lost its effort"
      fi
    done
  done
done
pass "suggestions retain effort and honor Kimi and typed Codex capture restrictions"

printf '%s\n' '{"default":[{"harness":"polytoken","model":"zai/glm-5.3-flash","effort":"low","provider":"codex"},{"harness":"claude"}]}' > "$CASE_DIR/poly-rules.json"
out=$(fm_quota_gate_explicit grok '' "$CASE_DIR/poly-rules.json" "$CASE_DIR/quota.json" ship tmux "$HOME_DIR/config")
assert_contains "$out" '--harness polytoken --model zai/glm-5.3-flash --effort low' "Polytoken suggestion lost a required axis"
jq 'del(.default[0].effort)' "$CASE_DIR/poly-rules.json" > "$CASE_DIR/poly-invalid.json"
out=$(fm_quota_gate_explicit grok '' "$CASE_DIR/poly-invalid.json" "$CASE_DIR/quota.json" ship tmux "$HOME_DIR/config")
assert_not_contains "$out" '--harness polytoken' "an unlaunchable Polytoken profile survived ranking"
for model in 'zai/glm-5.3-flash(low)' 'bad)selector' '@group' 'mg:group' 'modelgroup:group'; do
  jq --arg model "$model" '.default[0].model=$model' "$CASE_DIR/poly-rules.json" > "$CASE_DIR/poly-invalid.json"
  out=$(fm_quota_gate_explicit grok '' "$CASE_DIR/poly-invalid.json" "$CASE_DIR/quota.json" ship tmux "$HOME_DIR/config")
  assert_not_contains "$out" '--harness polytoken' "a Polytoken selector forbidden by launch survived ranking: $model"
done
pass "Polytoken alternatives retain concrete axes and reject selectors forbidden by launch"

export FM_TEST_FIXTURE_IMPORT=control-relaunch
# shellcheck source=tests/fm-control-relaunch.test.sh
. "$ROOT/tests/fm-control-relaunch.test.sh"
unset FM_TEST_FIXTURE_IMPORT
for quota_profile in "${quota_harness_profiles[@]}"; do
  IFS='|' read -r quota_harness quota_model <<< "$quota_profile"
  for quota_axis in caller configured; do
    [ "$quota_harness:$quota_axis" != polytoken:configured ] || continue
    id="quota-control-$quota_harness-$quota_axis"
    dir=$(new_case "$id" "$id")
    add_ship_task "$dir" "$id" claude
    quota_alternative=codex
    [ "$quota_harness" != codex ] || quota_alternative=claude
    jq -n --arg h "$quota_harness" --arg m "$quota_model" --arg alt "$quota_alternative" \
      '{default:[{harness:$h,model:$m,provider:"blocked"},{harness:$alt,model:"healthy-alternative"}]}' \
      > "$dir/home/config/crew-dispatch.json"
    fm_test_quota_snapshot "$dir/quota.json" through
    jq '.providers += [{provider:"blocked",quotaSemantics:{status:"known",effectiveAvailability:[
      {scope:"all_models",status:"known",effectivePercentRemaining:0,runway:{status:"exhausted_now"},selection:{spendPriority:-10}}]}}]' \
      "$dir/quota.json" > "$dir/all-models.json"
    quota_args=(--harness "$quota_harness")
    [ "$quota_axis" != caller ] || quota_args+=(--model "$quota_model")
    if [ "$quota_harness" = polytoken ]; then
      quota_args+=(--effort low)
      cat > "$dir/fakebin/polytoken" <<'POLY'
#!/usr/bin/env bash
[ "$*" = 'print models' ] || exit 1
printf '%s\n' 'zai/glm-5.3-flash' 'zai/glm-5.3-flash(low)'
POLY
      chmod +x "$dir/fakebin/polytoken"
    fi
    cp "$dir/home/state/$id.meta" "$dir/before.meta"
    out=$(FM_QUOTA_SNAPSHOT_FILE="$dir/all-models.json" \
      run_control "$dir" "$id" relaunch "${quota_args[@]}" --note 'exhausted explicit profile'); rc=$?
    expect_code 1 "$rc" "$quota_harness/$quota_axis must refuse exhausted relaunch quota: $out"
    assert_contains "$out" 'provider blocked runway exhausted_now at all_models' "$quota_harness relaunch bypassed the quota family"
    assert_contains "$out" "--harness $quota_alternative --model healthy-alternative" "$quota_harness relaunch lost its configured alternative"
    assert_not_contains "$out" 'unresolvable' "$quota_harness relaunch was incorrectly treated as unresolvable"
    [ ! -s "$dir/fake/literal" ] || fail "$quota_harness quota refusal sent lifecycle input"
    [ ! -s "$dir/fake/keys" ] || fail "$quota_harness quota refusal sent lifecycle keys"
    cmp -s "$dir/home/state/$id.meta" "$dir/before.meta" || fail "$quota_harness quota refusal changed metadata"
    [ "$(cat "$dir/fake/command")" = claude ] || fail "$quota_harness quota refusal stopped the running agent"
  done
  pass "explicit $quota_harness relaunch refuses exhausted quota before stopping its agent"
done

for lifecycle in ordinary released; do
  for delegation_case in refuse override notice; do
    id="quota-delegate-$lifecycle-$delegation_case"
    dir=$(new_case "$id" "$id")
    if [ "$lifecycle" = released ]; then add_released_ship_task "$dir" "$id"; else add_ship_task "$dir" "$id" claude; fi
    printf 'grok' > "$dir/fake/becomes"
    printf '%s\n' '{"default":[{"harness":"grok","model":"grok-4.7"},{"harness":"codex","model":"gpt-6.1-sol"}]}' > "$dir/home/config/crew-dispatch.json"
    fm_test_quota_snapshot "$dir/quota.json" exhausted
    delegation_snapshot="$dir/quota.json"
    delegation_args=(--harness grok --model grok-4.7 --note 'explicit delegated launch')
    if [ "$delegation_case" = override ]; then delegation_args+=(--quota-override 'delegated review override with spaces'); fi
    [ "$delegation_case" != notice ] || delegation_snapshot="$dir/unavailable.json"
    cp "$dir/home/state/$id.meta" "$dir/prior.meta"
    out=$(FM_QUOTA_SNAPSHOT_FILE="$delegation_snapshot" run_control "$dir" "$id" relaunch "${delegation_args[@]}"); rc=$?
    if [ "$delegation_case" = refuse ]; then
      expect_code 1 "$rc" "$lifecycle refusal must precede delegation: $out"
      assert_contains "$out" 'fm-control refuses explicit harness grok' "$lifecycle lost refusal diagnostics"
      cmp -s "$dir/prior.meta" "$dir/home/state/$id.meta" || fail "$lifecycle refusal changed metadata"
    else
      expect_code 0 "$rc" "$lifecycle $delegation_case must survive child delegation: $out"
      [ "$(meta_field "$dir" "$id" harness)" = grok ] || fail "$lifecycle did not launch the selected harness"
      if [ "$delegation_case" = override ]; then
        [ "$(meta_field "$dir" "$id" quota_override)" = 'delegated review override with spaces' ] || fail "$lifecycle lost override reason"
        assert_grep 'quota_override_evidence=refuse: provider grok' "$dir/home/state/$id.meta" "$lifecycle lost refusal evidence"
        [ "$(printf '%s\n' "$out" | grep -c '^notice: fm-control quota check refuses grok')" = 1 ] || fail "$lifecycle lost or duplicated override diagnostics: $out"
      else
        [ "$(printf '%s\n' "$out" | grep -c '^notice: fm-control launches grok without the quota check:')" = 1 ] || fail "$lifecycle lost or duplicated uncertainty diagnostics: $out"
        assert_no_grep 'quota_override=' "$dir/home/state/$id.meta" "$lifecycle uncertainty invented an override"
      fi
      assert_not_contains "$out" 'notice: fm-spawn quota check' "$lifecycle gated the delegated child a second time"
      assert_not_contains "$out" 'notice: fm-spawn launches grok without the quota check:' "$lifecycle re-read quota in its delegated child"
    fi
  done
  out=$(run_control "$dir" "$id" relaunch --quota-override 'implicit override' --note 'implicit'); rc=$?
  expect_code 1 "$rc" "$lifecycle must reject implicit overrides before delegation: $out"
  assert_contains "$out" 'only to a relaunch with an explicit --harness' "$lifecycle accepted an implicit override"
  pass "$lifecycle control delegation preserves explicit overrides, metadata, notices and refusals"
done

test_quota_gate_refuses_an_explicit_relaunch_before_the_agent_stops
test_secondmate_quota_relaunch_names_a_supported_alternative
test_quota_override_relaunches_and_is_recorded

test_refused_relaunch_onto_polytoken_keeps_the_project_hook_layer
test_explicit_secondmate_harness_ignores_configured_profile_axes

id=quota-implicit-relaunch
dir=$(quota_relaunch_case "$id" "$id" exhausted)
sed -i 's/^harness=claude$/harness=grok/' "$dir/home/state/$id.meta"
printf 'zsh' > "$dir/fake/command"
out=$(FM_QUOTA_SNAPSHOT_FILE="$dir/quota.json" run_spawn "$dir" "$id" --relaunch); rc=$?
expect_code 0 "$rc" "adopting the recorded harness must not add an explicit quota gate: $out"
assert_not_contains "$out" 'refuses explicit harness' "implicit direct relaunch was quota gated"
pass "direct relaunch without a caller-supplied harness stays ungated on exhausted quota"

id=quota-control-exclusions
dir=$(quota_relaunch_case quota-control-exclusions "$id" through)
printf 'hidden_tool\n' > "$dir/home/config/crew-exclude-tools"
printf '%s\n' '{"default":[{"harness":"pi","model":"glm-5.3","provider":"zai"},{"harness":"codex","model":"gpt-6.1-sol"},{"harness":"pi-signed","model":"codex-native/gpt-6-astra","provider":"codex"}]}' \
  > "$dir/home/config/crew-dispatch.json"
jq '(.providers[] | select(.provider == "zai").quotaSemantics.effectiveAvailability[]) |=
  (.effectivePercentRemaining=0 | .runway.status="exhausted_now")' "$dir/quota.json" > "$dir/exhausted.json"
out=$(FM_QUOTA_SNAPSHOT_FILE="$dir/exhausted.json" \
  run_control "$dir" "$id" relaunch --harness pi --model glm-5.3 --note 'check quota before exit'); rc=$?
expect_code 1 "$rc" "control must refuse the exhausted requested Pi model: $out"
assert_contains "$out" '--harness pi-signed --model codex-native/gpt-6-astra' "control recommended an excluded runtime"
[ ! -s "$dir/fake/literal" ] || fail "control stopped the worker during quota refusal"
pass "relaunch quota alternatives honor worker exclusions before stopping the agent"

test_herdr_relaunch_resumes_only_the_registered_pi_session

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
printf '%s\n' '{"default":[{"harness":"omp","model":"openai-codex/gpt-6.1-sol","provider":"omp-quota"},{"harness":"codex","model":"gpt-6.1-sol"}]}' > "$remote_home/config/crew-dispatch.json"
jq '.providers += [{provider:"omp-quota",quotaSemantics:{status:"known",effectiveAvailability:[
  {scope:"all_models",status:"known",effectivePercentRemaining:90,runway:{status:"through_reset"},selection:{spendPriority:9}}]}}]' \
  "$dir/quota.json" > "$dir/route-quota.json"
mv "$dir/route-quota.json" "$dir/quota.json"
host_meta="$remote_home/state/parent-route/$id.meta"
out=$(run_host launch "$id" grok - - herdr); rc=$?
expect_code 1 "$rc" "host launch must refuse exhausted Grok: $out"
assert_contains "$out" '--harness codex --model gpt-6.1-sol' "host launch lost its remote-eligible recommendation"
assert_not_contains "$out" '--harness omp' "host launch recommended unsupported OMP"
[ ! -e "$host_meta" ] || fail "refused remote launch created task metadata"
out=$(run_host launch "$id" grok - - herdr --quota-override 'remote launch override'); rc=$?
expect_code 0 "$rc" "host launch must honor the explicit override: $out"
grep -Fxq 'quota_override=remote launch override' "$host_meta" || fail "host lost launch override"
assert_grep 'quota_override_evidence=refuse: provider grok' "$host_meta" "host lost launch refusal evidence"
cp "$host_meta" "$dir/before-relaunch.meta"
out=$(run_host relaunch "$id" grok - -); rc=$?
expect_code 1 "$rc" "host relaunch must refuse exhausted Grok without an override: $out"
assert_contains "$out" '--harness codex --model gpt-6.1-sol' "host relaunch lost its remote-eligible recommendation"
assert_not_contains "$out" '--harness omp' "host relaunch recommended unsupported OMP"
cmp -s "$host_meta" "$dir/before-relaunch.meta" || fail "refusal changed remote metadata"
out=$(run_host relaunch "$id" grok - - --quota-override 'remote relaunch override'); rc=$?
expect_code 0 "$rc" "host relaunch must honor the explicit override: $out"
grep -Fxq 'quota_override=remote relaunch override' "$host_meta" || fail "host lost relaunch override"
assert_contains "$out" 'quota_override_evidence=refuse: provider grok' "route confirmation lost host evidence"
[ "$(printf '%s\n' "$out" | grep -c '^notice: fm-control quota check refuses grok')" = 1 ] || fail "host relaunch lost override diagnostics: $out"
mv "$dir/quota.json" "$dir/saved-quota.json"
out=$(run_host relaunch "$id" grok - -); rc=$?
expect_code 0 "$rc" "uncertain host relaunch must succeed with a notice: $out"
[ "$(printf '%s\n' "$out" | grep -c '^notice: fm-control launches grok without the quota check:')" = 1 ] || fail "host relaunch swallowed or duplicated uncertainty: $out"
assert_no_grep 'quota_override=' "$host_meta" "uncertain host relaunch retained a stale override"
mv "$dir/saved-quota.json" "$dir/quota.json"
pass "remote host launch and relaunch preserve overrides, route eligibility and diagnostics"
