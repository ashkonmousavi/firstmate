#!/usr/bin/env bash
# fm-gh-rate-check.sh - watch what is left of the fleet's shared GitHub allowance.
#
# Usage:
#   fm-gh-rate-check.sh [check]   evaluate at most once per FM_GH_RATE_INTERVAL
#   fm-gh-rate-check.sh report    read now and print core and GraphQL remaining
#   fm-gh-rate-check.sh arm       write and register state/gh-rate.check.sh
#   fm-gh-rate-check.sh disarm    remove the shim, its trust binding and the record
#   fm-gh-rate-check.sh --help
#
# WHY. Every request from the fleet's one personal token, on every machine and
# worker, spends the same 5,000-per-hour core budget, and GraphQL has its own
# 5,000-point budget (data/research-book/github-rate-limits.md). A polling bug
# once exhausted the core budget with no warning. This check is the warning.
# It is a sibling of the quota watch (bin/fm-procevent-quota.sh), not an edit
# of it: that watch is a one-shot reader of quota-axi's model windows and stops
# after it fires, while this allowance is a recurring reading of GitHub's own
# rate_limit endpoint with an episode that ends when the window refills.
#
# THE READING. `gh api rate_limit` does not count against any budget. check and
# report read resources.core and resources.graphql: limit, remaining and the
# reset epoch. report prints both on every machine whether or not they are low.
#
# ONE WAKE PER EPISODE. An episode is one budget window, named by that
# resource's reset epoch. When remaining falls below FM_GH_RATE_THRESHOLD
# percent of the limit (default 25) and this window has not fired yet for the
# resource, check fires once and records the reset epoch; later checks in the
# same window stay silent however low it goes. The refill starts a new window,
# so a later shortage fires again. core and graphql are independent episodes.
#
# WHERE IT WAKES. A main home prints the line, which the watcher turns into an
# ordinary `check:` wake. A secondmate home would only wake its idle mate, so it
# publishes `blocked [key=gh-rate-<resource>-<reset>]` on its parent channel
# (bin/fm-parent-channel-lib.sh) and prints nothing; the same key is closed with
# `resolved` once the resource is back above the threshold. If the channel
# cannot be written the line is printed, so the failure is seen locally.
#
# FAILURE IS QUIET BUT VISIBLE. A missing gh, a failed or slow read, or an
# unexpected shape prints nothing and leaves the record alone, so the next
# interval retries; report exits 1 and says why.
#
# Tunables (env): FM_GH_RATE_THRESHOLD percent 1..99 (default 25),
# FM_GH_RATE_INTERVAL seconds between check readings (default 300),
# FM_GH_RATE_BOUND seconds allowed for one read (default 15),
# FM_GH_RATE_NOW epoch override for tests.
#
# `arm` writes state/gh-rate.check.sh, which execs this script's `check`, and
# binds its bytes with fm-check-register.sh, so the watcher's ordinary check
# cadence runs it on every machine that arms it. Arm once per home, in that
# home's own FM_HOME; docs/configuration.md lists the exact commands.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID=gh-rate
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.gh-rate-check"
RECORD_SCHEMA=fm-gh-rate-check-v1

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

usage() { sed -n '2,/^set -u/{/^set -u/d;s/^# \{0,1\}//;p;}' "$0"; }
fail() { printf 'fm-gh-rate-check: %s\n' "$1" >&2; exit 1; }

now_epoch() {
  case "${FM_GH_RATE_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_GH_RATE_NOW" ;;
  esac
}

num_or() {  # <value> <default> <min> <max>
  case "$1" in
    ''|*[!0-9]*) printf '%s\n' "$2"; return ;;
  esac
  if [ "$1" -lt "$3" ] || [ "$1" -gt "$4" ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi
}
THRESHOLD=$(num_or "${FM_GH_RATE_THRESHOLD:-}" 25 1 99)
INTERVAL=$(num_or "${FM_GH_RATE_INTERVAL:-}" 300 1 86400)
BOUND=$(num_or "${FM_GH_RATE_BOUND:-}" 15 1 120)

# Read both resources into R_<name>_LIMIT/_REMAINING/_RESET. Nonzero on any
# trouble, with the reason in READ_WHY.
READ_WHY=
read_rates() {
  local json rc=0 line name limit remaining reset
  READ_WHY=
  command -v gh >/dev/null 2>&1 || { READ_WHY="gh is not installed"; return 1; }
  command -v jq >/dev/null 2>&1 || { READ_WHY="jq is not installed"; return 1; }
  json=$(fm_run_timed "$BOUND" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh api rate_limit 2>/dev/null </dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then READ_WHY="gh api rate_limit failed (exit $rc)"; return 1; fi
  while IFS=$'\t' read -r name limit remaining reset; do
    case "$name" in core|graphql) ;; *) continue ;; esac
    case "$limit$remaining$reset" in ''|*[!0-9]*) READ_WHY="rate_limit returned a non-numeric $name reading"; return 1 ;; esac
    eval "R_${name}_LIMIT=\$limit R_${name}_REMAINING=\$remaining R_${name}_RESET=\$reset"
  done < <(printf '%s' "$json" | jq -r '.resources | to_entries[] | select(.key == "core" or .key == "graphql")
    | [.key, (.value.limit // ""), (.value.remaining // ""), (.value.reset // "")] | @tsv' 2>/dev/null)
  if [ -z "${R_core_LIMIT:-}" ] || [ -z "${R_graphql_LIMIT:-}" ]; then
    READ_WHY="rate_limit lacked core or graphql"
    return 1
  fi
}

percent() {  # <remaining> <limit>
  [ "$2" -gt 0 ] || { printf '0\n'; return; }
  printf '%s\n' $(( $1 * 100 / $2 ))
}
is_low() {  # <remaining> <limit>
  [ "$2" -gt 0 ] && [ $(( $1 * 100 )) -lt $(( THRESHOLD * $2 )) ]
}
iso() {  # <epoch>
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s\n' "$1"
}

describe() {  # <name>
  local name=$1 limit remaining reset
  eval "limit=\$R_${name}_LIMIT remaining=\$R_${name}_REMAINING reset=\$R_${name}_RESET"
  printf 'github-%s: remaining=%s limit=%s percent=%s reset=%s' \
    "$name" "$remaining" "$limit" "$(percent "$remaining" "$limit")" "$(iso "$reset")"
}

# Record: schema line, then `<name> <fired-reset>` per resource and
# `checked <epoch>`. Fired-reset is 0 while no episode has fired.
FIRED_core=0
FIRED_graphql=0
LAST_CHECKED=0
record_read() {
  local line key val
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  IFS= read -r line < "$RECORD" || return 0
  [ "$line" = "$RECORD_SCHEMA" ] || return 0
  while IFS=' ' read -r key val; do
    case "$val" in ''|*[!0-9]*) continue ;; esac
    case "$key" in
      core) FIRED_core=$val ;;
      graphql) FIRED_graphql=$val ;;
      checked) LAST_CHECKED=$val ;;
    esac
  done < "$RECORD"
}
record_write() {
  local tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  if [ -e "$RECORD" ] || [ -L "$RECORD" ]; then
    [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.gh-rate-check.XXXXXX" 2>/dev/null) || return 0
  printf '%s\ncore %s\ngraphql %s\nchecked %s\n' "$RECORD_SCHEMA" "$FIRED_core" "$FIRED_graphql" "$1" > "$tmp" \
    && mv -f -- "$tmp" "$RECORD" || rm -f -- "$tmp"
}

# Deliver one episode line: parent channel in a secondmate home, stdout
# otherwise (and as the fallback when the channel cannot be written).
deliver() {  # <status-line> <print-line>
  local rc=0
  fm_parent_channel_report "$FM_HOME" "$STATE" "$1" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) [ -z "$2" ] || printf '%s\n' "$2" ;;
    *) printf '%s (parent channel unavailable, rc=%s)\n' "${2:-$1}" "$rc" ;;
  esac
}

run_check() {
  local now name limit remaining reset fired out
  now=$(now_epoch)
  record_read
  if [ "$LAST_CHECKED" -gt 0 ] && [ $(( now - LAST_CHECKED )) -lt "$INTERVAL" ] && [ "$now" -ge "$LAST_CHECKED" ]; then
    return 0
  fi
  read_rates || return 0
  for name in core graphql; do
    eval "limit=\$R_${name}_LIMIT remaining=\$R_${name}_REMAINING reset=\$R_${name}_RESET fired=\$FIRED_${name}"
    if is_low "$remaining" "$limit"; then
      [ "$fired" != "$reset" ] || continue
      eval "FIRED_${name}=\$reset"
      out="GitHub $name allowance low: $remaining of $limit left ($(percent "$remaining" "$limit")%), window resets $(iso "$reset"); all machines share it, so slow or pause GitHub-heavy polling"
      deliver "blocked [key=gh-rate-$name-$reset]: $out" "$out"
    elif [ "$fired" != 0 ]; then
      eval "FIRED_${name}=0"
      deliver "resolved [key=gh-rate-$name-$fired]: GitHub $name allowance recovered to $remaining of $limit" ""
    fi
  done
  record_write "$now"
}

run_report() {
  read_rates || { printf 'github-rate: unavailable: %s\n' "$READ_WHY"; exit 1; }
  describe core; printf '\n'
  describe graphql; printf '\n'
}

arm() {
  local home tmp
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || fail "cannot resolve FM_HOME $FM_HOME" ;;
  esac
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
  [ ! -L "$CHECK_SHIM" ] || fail "$CHECK_SHIM is a symlink"
  tmp=$(umask 077; mktemp "$STATE/.fm-gh-rate-check-shim.XXXXXX") || fail "could not create the check shim"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-gh-rate-check.sh - the GitHub allowance check shim.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-gh-rate-check.sh") check" > "$tmp" \
    && chmod 0700 "$tmp" && mv -f -- "$tmp" "$CHECK_SHIM" || { rm -f -- "$tmp"; fail "could not write the check shim"; }
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
    fail "could not register the check shim"
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check)  [ "$#" -le 1 ] || { usage >&2; exit 2; }; run_check ;;
  report) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; run_report ;;
  arm)    [ "$#" -eq 1 ] || { usage >&2; exit 2; }; arm ;;
  disarm) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; disarm ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
