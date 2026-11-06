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
  case_dir="$TMP_ROOT/$profile"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  id="lane-native-$profile"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$project" "$worktree" "wt-$profile"
  # Native discovery reads an isolated complete configuration, without
  # starting these transports. A second isolated config proves process startup.
  mkdir -p "$home/user-home/.codex"
  cat > "$home/user-home/.codex/config.toml" <<'TOML'
[mcp_servers.gitnexus]
command = "false"
[mcp_servers.claude-context]
command = "false"
[mcp_servers.retained]
command = "false"
TOML
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$NATIVE_CODEX" > "$fakebin/codex"
  chmod +x "$fakebin/codex"
  FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$worktree" "$fakebin" \
    "$id" "$project" --mode local-only --yolo off --lane-profile "$profile" >/dev/null ||
    fail "$CODEX_VERSION: failed to capture $profile spawn"
  python3 "$ROOT/tests/lane-profile-native.py" "$NATIVE_CODEX" "$profile" "$case_dir/native" "$launchlog" ||
    fail "$CODEX_VERSION: real MCP process-start proof failed for $profile"
done
