#!/usr/bin/env bash
# Real provisioning and inheritance libraries; disposable homes, no actors.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-machine-policy)
policy_host_root="$TMP_ROOT/host-root"
policy_home="$TMP_ROOT/remote-home"
policy_parent="$TMP_ROOT/main"
git clone -q --shared "$ROOT" "$policy_host_root"
# Gate worktrees have detached HEADs; give the disposable host a default branch.
git -C "$policy_host_root" checkout -q -B main
git clone -q --shared "$ROOT" "$policy_parent"
mkdir -p "$policy_host_root/config" "$policy_parent/"{config,data,state}
printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nproject_count=0\n' \
  "$(printf server-test | base64 | tr -d '\n')" "$(printf 'Fixture charter\n' | base64 | tr -d '\n')" > "$TMP_ROOT/manifest"
provision() {
  FM_HOME="$policy_home" FM_ROOT_OVERRIDE="$policy_host_root" bash "$ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/manifest"
}
rc=0; out=$(provision 2>&1) || rc=$?
expect_code 1 "$rc" 'missing target policy refuses before clone'
assert_contains "$out" "$policy_host_root/config/machine-admission.json" 'refusal names target path'
assert_absent "$policy_home" 'missing policy must not create a home'
printf 'broken\n' > "$policy_host_root/config/machine-admission.json"
rc=0; out=$(provision 2>&1) || rc=$?
expect_code 1 "$rc" 'malformed target policy refuses'
assert_absent "$policy_home" 'malformed policy must not create a home'
pass 'missing and malformed target policy refuse before home publication'

jq -n '{schema:"fm-machine-admission.v1",memory_floor_gib:1.5,memory_full_avg60_max:5,disk_floor_gib:5,disk_paths:["/server-home","/tmp"]}' > "$policy_host_root/config/machine-admission.json"
rc=0; out=$(provision 2>&1) || rc=$?
expect_code 1 "$rc" 'missing target lane declaration refuses'
assert_contains "$out" "$policy_host_root/config/lane-capacity" 'refusal names lane declaration'
assert_absent "$policy_home" 'missing lane declaration must not create a home'
printf '6 malformed\n' > "$policy_host_root/config/lane-capacity"
rc=0; out=$(provision 2>&1) || rc=$?
expect_code 1 "$rc" 'malformed target lane declaration refuses'
assert_absent "$policy_home" 'malformed lane declaration must not create a home'
pass 'missing and malformed target lane declaration refuse before publication'
printf '6 2\n' > "$policy_host_root/config/lane-capacity"
jq '.memory_floor_gib=3 | .disk_paths=["/pc-home","/tmp"]' "$policy_host_root/config/machine-admission.json" > "$policy_parent/config/machine-admission.json"
printf '5 4\n' > "$policy_parent/config/lane-capacity"
provision >/dev/null
cmp "$policy_host_root/config/machine-admission.json" "$policy_home/config/machine-admission.json"
cmp "$policy_host_root/config/lane-capacity" "$policy_home/config/lane-capacity"
test -f "$policy_home/.fm-secondmate-home"
test -f "$policy_home/bin/fm-machine-resources.py"
pass 'real remote provisioning seeds server policy and helper without PC values'

# Ordinary inheritance uses its actual unmodified allowlist, not a test override.
(
  unset FM_INHERITABLE_CONFIG
  FM_ROOT="$ROOT" FM_HOME="$policy_parent" FM_CONFIG_INHERIT_LIVE=0
  export FM_ROOT FM_HOME FM_CONFIG_INHERIT_LIVE
  # shellcheck source=bin/fm-config-inherit-lib.sh
  . "$ROOT/bin/fm-config-inherit-lib.sh"
  propagate_inheritable_config "$policy_parent/config" "$policy_home/config" "$policy_parent"
)
cmp "$policy_host_root/config/machine-admission.json" "$policy_home/config/machine-admission.json"
cmp "$policy_host_root/config/lane-capacity" "$policy_home/config/lane-capacity"
pass 'generic inheritance preserves target floor, paths, ceiling and reserve'

cp "$policy_home/config/machine-admission.json" "$TMP_ROOT/prior-policy"
printf 'broken\n' > "$policy_host_root/config/machine-admission.json"
provision >/dev/null
cmp "$TMP_ROOT/prior-policy" "$policy_home/config/machine-admission.json"
pass 'existing home validates and preserves its own policy on reseed'

printf 'fixture change\n' > "$policy_host_root/policy-update-fixture"
git -C "$policy_host_root" add policy-update-fixture
git -C "$policy_host_root" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
target=$(git -C "$policy_host_root" rev-parse HEAD)
git -C "$policy_home" fetch -q origin
(
  FM_ROOT="$ROOT" FM_HOME="$policy_parent"
  # shellcheck source=bin/fm-ff-lib.sh
  . "$ROOT/bin/fm-ff-lib.sh"
  ff_target "$policy_home" fixture "$target" no no
  [ "$FF_STATUS" = updated ]
)
cmp "$TMP_ROOT/prior-policy" "$policy_home/config/machine-admission.json"
pass 'tracked guarded update preserves ignored host policy bytes'

cp "$policy_home/config/machine-admission.json" "$TMP_ROOT/valid-policy"
printf 'broken\n' > "$policy_home/config/machine-admission.json"
rc=0; out=$(provision 2>&1) || rc=$?
expect_code 1 "$rc" 'existing malformed policy refuses rather than silently replacing it'
assert_contains "$out" "$policy_home/config/machine-admission.json" 'existing policy correction is named'
pass 'existing malformed policy is an explicit technical correction'
