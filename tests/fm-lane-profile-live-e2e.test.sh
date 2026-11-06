#!/usr/bin/env bash
# Token-free real Codex process-start proof for captured lane-profile launches.
# Local MCP fixtures isolate process startup from credentials and shared indexes.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate default-on FM_LANE_PROFILE_LIVE codex python3
NATIVE_CODEX=$(command -v codex)
CODEX_VERSION=$(codex --version)
TMP_ROOT=$(fm_test_tmproot fm-lane-profile-live)
profiles=("$@")
[ "$#" -gt 0 ] || profiles=(product-code ci-tooling governance)
for profile in "${profiles[@]}"; do
  case "$profile" in product-code | ci-tooling | governance) ;; *) fail "unknown live profile: $profile" ;; esac
  for source in global trusted-project untrusted-project; do
    case_dir="$TMP_ROOT/$profile-$source"
    home="$case_dir/home"
    project="$case_dir/project"
    worktree="$case_dir/wt"
    launchlog="$case_dir/launch.log"
    id="lane-native-$profile-$source"
    fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
    fm_test_spawn_home "$home" codex
    fm_test_spawn_brief "$home" "$id"
    printf '%s\n' custom_index > "$home/config/code-index-mcp-servers"
    fm_git_worktree "$project" "$worktree" "wt-$profile-$source"
    printf '%s\n' .codex/ >> "$project/.git/info/exclude"
    codex_home="$home/user-home/.codex"
    python3 "$ROOT/tests/lane-profile-native.py" prepare "$case_dir/native" "$codex_home" "$worktree" "$source" || fail 'native fixture preparation failed'
    if [ "$source" = trusted-project ]; then
      printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$worktree" >> "$codex_home/config.toml"
    fi
    printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$NATIVE_CODEX" > "$fakebin/codex"
    chmod +x "$fakebin/codex"
    out=$(CODEX_HOME="$codex_home" FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$worktree" "$fakebin" \
      "$id" "$project" --mode local-only --yolo off --lane-profile "$profile" 2>&1); status=$?
    if [ "$source" = untrusted-project ]; then
      if [ "$profile" != product-code ]; then
        [ "$status" -ne 0 ] || fail "$CODEX_VERSION: accepted hidden project index servers"
        assert_contains "$out" 'stable project trust' 'untrusted discovery must identify the refusal'
        [ ! -s "$launchlog" ] || fail 'untrusted refusal delivered a launch'
        [ ! -e "$home/state/$id.meta" ] || fail 'untrusted refusal published task metadata'
        printf 'ok - %s %s: hidden project indexes refused before launch\n' "$CODEX_VERSION" "$profile"
      fi
      printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$worktree" >> "$codex_home/config.toml"
      if [ "$profile" != product-code ]; then
        out=$(CODEX_HOME="$codex_home" FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$worktree" "$fakebin" \
          "$id" "$project" --mode local-only --yolo off --lane-profile "$profile" 2>&1); status=$?
      fi
    fi
    expect_code 0 "$status" "$out"
    python3 "$ROOT/tests/lane-profile-native.py" "$NATIVE_CODEX" "$profile" "$case_dir/native" "$launchlog" "$codex_home" "$worktree" ||
      fail "$CODEX_VERSION: real MCP process-start proof failed for $profile/$source"
  done
done
