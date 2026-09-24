#!/usr/bin/env bash
# Resolve one already-matched crew-dispatch rule without launching anything.
# Usage: fm-dispatch-select.sh CONFIG RULE [--facts FILE]
#        fm-dispatch-select.sh --help
# RULE is a zero-based rules index or "default"; when text is never matched.
# Reads CONFIG and optional FILE once, writes no state, invokes no vendor tools.
# The schema owner is docs/configuration.md, Crew dispatch profiles.
#
# FILE is one JSON array of candidate-indexed intake facts (zero-based indices
# within this rule). Firstmate establishes applicability; no harness/provider
# mapping, credential discovery, or quota collection happens here. Fact shapes:
#   {"candidate":0,"kind":"launch_failed","detail":"concrete failure"}
#   {"candidate":0,"kind":"blocked","detail":"concrete known block"}
#   {"candidate":0,"kind":"quota","provider":"catalog-established provider",
#    "runway":"exhausted_now","confidence":"established"}
# Quota runway: exhausted_now|projected_exhaustion|through_reset|unknown.
# Confidence: established|early|unknown. Only exhausted_now + established skips;
# lower headroom and extra quota fields do not affect ordered selection.
# Multiple facts per candidate are allowed and applicable reasons are combined.
#
# Stdout: selection mode, skipped[index]: reason; profile=<compact JSON>, then
# selected[index]: <compact JSON>. Ordered stops at the first available profile.
# quota-balanced prints a handoff to quota-array-dispatch without any selection.
# Exit 0: selected or quota handoff; 1: all unavailable (every skip on stdout);
# 2: invalid input (one-line reason on stderr). No other rule is tried on failure.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() {
  sed -n '2,/^set -eu/{ /^set -eu/d; s/^# \{0,1\}//; p; }' "$0"
}
refuse() {
  local message=$1
  message=${message//$'\n'/ }
  message=${message//$'\r'/ }
  printf 'error: %s\n' "$message" >&2
  exit 2
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ "$#" -eq 2 ] || [ "$#" -eq 4 ] || refuse 'usage: fm-dispatch-select.sh CONFIG RULE [--facts FILE]'
command -v jq >/dev/null 2>&1 || refuse 'jq is required'
config_file=$1
selector=$2
facts='[]'
if [ "$#" -eq 4 ]; then
  [ "$3" = --facts ] || refuse 'expected --facts FILE'
  facts=$(jq -cs 'if length == 1 and (.[0] | type) == "array" then .[0] else error("facts must be one array") end' "$4" 2>/dev/null) \
    || refuse 'facts must be one readable JSON array'
fi
config=$(jq -cs . "$config_file" 2>/dev/null) || refuse 'config: malformed JSON or unreadable file'
err=$(printf '%s\n' "$config" | jq -r -f "$SCRIPT_DIR/fm-crew-dispatch-validate.jq" 2>/dev/null) \
  || refuse 'config validation failed'
[ -z "$err" ] || refuse "config: $err"
case "$selector" in
  default) ;;
  *) [[ "$selector" =~ ^(0|[1-9][0-9]*)$ ]] || refuse 'selector must be a zero-based rule index or default' ;;
esac
rule=$(printf '%s\n' "$config" | jq -ce --arg s "$selector" '
  .[0] |
  if $s == "default" then
    if has("default") then {use:.default} else empty end
  else (.rules // []) | .[$s|tonumber] | select(. != null) end
  | .use |= (if type == "array" then . else [.] end)
' 2>/dev/null) || refuse "selector $selector names no rule"
count=$(printf '%s\n' "$rule" | jq '.use | length')
if ! printf '%s\n' "$facts" | jq -e --argjson count "$count" '
  def text: type == "string" and test("\\S");
  all(.[];
    if type != "object" then false
    elif (.candidate | type) != "number" then false
    elif .candidate < 0 or .candidate >= $count or (.candidate | floor) != .candidate then false
    elif .kind == "launch_failed" or .kind == "blocked" then (.detail | text)
    elif .kind == "quota" then
      (.provider | text) and
      (.runway as $r | ["exhausted_now","projected_exhaustion","through_reset","unknown"] | index($r) != null) and
      (.confidence as $c | ["established","early","unknown"] | index($c) != null)
    else false end)
' >/dev/null 2>&1; then
  refuse 'facts require an existing candidate index and a concrete launch_failed, blocked, or valid quota fact'
fi
if [ "$(printf '%s\n' "$rule" | jq -r '.select // "ordered"')" = quota-balanced ]; then
  printf '%s\n' 'selection: quota-balanced; use quota-array-dispatch'
  exit 0
fi
result=$(printf '%s\n' "$rule" | jq -c --argjson facts "$facts" '
  .use | to_entries | map(
    . as $p |
    ([if .value.off == true then "off=true" else empty end] +
      [$facts[] | select(.candidate == $p.key) |
        if .kind == "launch_failed" or .kind == "blocked" then "\(.kind): \(.detail)"
        elif .runway == "exhausted_now" and .confidence == "established" then
          "quota: \(.provider) exhausted_now (established)"
        else empty end]) as $reasons |
    {index:.key, profile:.value, reasons:$reasons}) |
  (map(select(.reasons | length == 0)) | .[0]) as $choice |
  {choice:$choice, skipped:map(select($choice == null or .index < $choice.index))}
')
printf '%s\n' 'selection: ordered'
printf '%s\n' "$result" | jq -r '
  .skipped[] | "skipped[\(.index)]: \(.reasons | join("; ") | gsub("[\r\n]"; " ")); profile=\(.profile | tojson)"
'
if printf '%s\n' "$result" | jq -e '.choice != null' >/dev/null; then
  printf '%s\n' "$result" | jq -r '.choice | "selected[\(.index)]: \(.profile | tojson)"'
else
  printf '%s\n' 'error: all candidates unavailable' >&2
  exit 1
fi
