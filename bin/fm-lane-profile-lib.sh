#!/usr/bin/env bash
# Lane-profile validation and Codex per-launch MCP settings.
# Sourced by fm-spawn.sh and fm-control.sh; docs/configuration.md owns the
# operator contract. Default product-code does no discovery and emits no flags.
# fm_lane_profile_check <profile> <harness> <raw 0|1> <kind> [backend]
# fm_lane_profile_flags <profile> <harness> <raw> <kind> <config-dir> <cwd>
# Discovery reads are bounded to 15 seconds and filtered directly to server IDs;
# secret-bearing MCP configuration is never returned to the caller or logged.
# shellcheck source=bin/fm-timeout-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-timeout-lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/fm-config-inherit-lib.sh"

fm_lane_profile_codex_home() {
  local profile=$1 config=$2 root=$3 filtered
  [ "$profile" != product-code ] || return 0
  if [ -z "$root" ]; then
    filtered=$(fm_config_source_present "$config/launch-env-allowlist") || return 1
    if [ "$filtered" = 1 ]; then
      echo 'error: reduced lane-profile requires an explicit Codex worker account with config/launch-env-allowlist; cannot establish the worker configuration before launch' >&2
      return 1
    fi
    root=${CODEX_HOME:-${HOME:+$HOME/.codex}}
  fi
  case "$root" in
    /*) printf '%s\n' "$root" ;;
    *) echo 'error: reduced lane-profile requires an absolute Codex configuration root' >&2; return 1 ;;
  esac
}

fm_lane_profile_check() {
  local profile=$1 harness=$2 raw=$3 kind=$4 backend=${5:-}
  case "$profile" in
  product-code) return 0 ;;
  ci-tooling | governance) ;;
  *) echo "error: unknown --lane-profile '$profile'; expected product-code, ci-tooling, or governance" >&2; return 1 ;;
  esac
  if [ "$harness" != codex ] || [ "$raw" != 0 ] || [ "$kind" = secondmate ]; then
    echo "error: --lane-profile $profile requires a canonical Codex ship/scout launch; reduced MCP startup is not verified for $harness/$kind (raw=$raw)" >&2
    return 1
  fi
  if [ "$backend" = t3code ]; then
    echo "error: backend=t3code cannot apply --lane-profile $profile; provider launch bypasses the shell command" >&2
    return 1
  fi
}

fm_lane_profile_server_names() { # <config-dir>
  local file=$1/code-index-mcp-servers line present
  present=$(perl -MErrno=ENOENT -e '
    if (lstat $ARGV[0]) { print 1 }
    elsif ($! == ENOENT) { print 0 }
    else { die "error: cannot inspect code-index-mcp-servers: $!\n" }
  ' -- "$file") || return 1
  printf '%s\n' gitnexus claude-context
  [ "$present" = 1 ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo 'error: config/code-index-mcp-servers must be a readable regular file' >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in '' | '#'*) continue ;; esac
    if [ -n "${line//[A-Za-z0-9_-]/}" ]; then
      echo 'error: config/code-index-mcp-servers requires one server ID per line using letters, digits, _ or -' >&2
      return 1
    fi
    printf '%s\n' "$line"
  done < "$file" || return 1
}

fm_lane_profile_flags() {
  local profile=$1 harness=$2 raw=$3 kind=$4 config=$5 cwd=$6 names selected server
  fm_lane_profile_check "$profile" "$harness" "$raw" "$kind" || return 1
  [ "$profile" != product-code ] || return 0
  names=$(fm_lane_profile_server_names "$config") || return 1
  names=$(printf '%s\n' "$names" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique') || return 1
  cwd=$(cd -- "$cwd" && pwd -P) || return 1
  python3 "$(dirname "${BASH_SOURCE[0]}")/fm-codex-accounts.py" lane-profile-preflight \
    --folder "${CODEX_HOME:-$HOME/.codex}" --cwd "$cwd" || return 1
  selected=$(
    cd -- "$cwd" || exit 1
    set -o pipefail
    fm_run_timed 15 codex mcp list --json 2>/dev/null |
      jq -ce --argjson wanted "$names" '
        if type == "array" and all(.[]; type == "object" and (.name | type == "string"))
        then [.[] | .name as $name | select($wanted | index($name)) | .name] | unique
        else error("invalid MCP server list") end
      ' 2>/dev/null
  ) || {
    echo 'error: lane-profile could not read a valid Codex MCP server list within 15 seconds; refusing before launch' >&2
    return 1
  }
  while IFS= read -r server; do
    [ -n "$server" ] || continue
    printf -- "-c 'mcp_servers.%s.enabled=false' " "$server"
  done < <(printf '%s\n' "$selected" | jq -r '.[]')
}
