#!/usr/bin/env bash
# Shared Q walk lifecycle for Grok dispatch, ordinary spawn and teardown.
# fm_walk_claim <walk> <owner> <seconds> publishes before launch and returns JSON.
# fm_walk_release <walk> <owner> <token> releases only that operation.
# The home-private executable ${FM_HOME}/data/walk-marker/transport (override:
# FM_WALK_MARKER_TRANSPORT) receives those arguments and executes the marker
# program from stdin on the walked host. Every call has a 30-second deadline
# and one-second kill grace. FM_TEST_SEAM=1 permits FM_WALK_MARKER_TEST_BOUND
# to select a shorter positive integer deadline in behavior tests.
# fm_walk_meta_read <meta> validates the optional walk_id, walk_owner,
# walk_token and walk_expires_at fields and exports FM_WALK_META_* values.
# Relaunch preserves these fields; expiry is the ordinary worker's timeout.
set -u

FM_WALK_MARKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_WALK_MARKER_LIB_DIR/fm-timeout-lib.sh"

fm_walk_options_valid() {
  local id_re='^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
  [[ "$1" =~ $id_re && "$2" =~ $id_re && "$3" =~ ^[1-9][0-9]*$ ]] || {
    echo 'error: --walk, --walk-owner and a positive walk timeout are required together' >&2
    return 1
  }
}

fm_walk_marker() {
  local op=$1 walk=$2 owner=$3 argument=$4 receipt rc bound=30
  local transport=${FM_WALK_MARKER_TRANSPORT:-${FM_HOME:?}/data/walk-marker/transport}
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_WALK_MARKER_TEST_BOUND:-}" ]; then
    [[ "$FM_WALK_MARKER_TEST_BOUND" =~ ^[1-9][0-9]*$ ]] || return 1
    bound=$FM_WALK_MARKER_TEST_BOUND
  fi
  [ -x "$transport" ] || { echo "walk marker transport not found: $transport" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo 'jq required for walk receipts' >&2; return 1; }
  receipt=$(fm_exec_timed "$bound" 1 "$transport" "$op" "$walk" "$owner" "$argument" \
    < "$FM_WALK_MARKER_LIB_DIR/fm-walk-marker.py" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if fm_timed_out "$rc"; then
      printf 'walk marker %s transport timeout after %ss\n' "$op" "$bound" >&2
    else
      printf '%s\n' "${receipt:0:300}" >&2
    fi
    return 1
  fi
  if ! jq -se --arg op "$op" --arg walk "$walk" --arg owner "$owner" '
    def utc:
      type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
      and (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == .) catch false);
    def marker:
      .owner == $owner and (.walks | type == "array" and length > 0)
      and all(.walks[]; type == "string" and test("\\S"))
      and ((.walks | unique | length) == (.walks | length))
      and (.started | utc) and (.expires_at | utc) and (.expires_at > .started);
    def tokens:
      (.claims | type == "object") and ((.claims | keys) == (.walks | sort))
      and all(.claims[]; type == "string" and test("^[0-9a-f]{16}$"));
    length == 1 and (.[0] | type == "object" and
      if $op == "claim" then
        .result == "claimed" and marker and tokens and (.walks | index($walk) != null)
        and .token == .claims[$walk]
      elif .result == "cleared" or .result == "absent" then
        .walks == null and .owner == null and .started == null and .expires_at == null and .claims == null
      elif .result == "released" then
        marker and tokens and (.walks | index($walk) == null)
      else
        .result == "not-listed" and marker and ((has("claims") | not) or tokens)
        and (.walks | index($walk) == null)
      end)
  ' <<<"$receipt" >/dev/null 2>&1; then
    printf 'invalid %s receipt: %s\n' "$op" "${receipt:0:300}" >&2
    return 1
  fi
  printf '%s\n' "$receipt"
}

fm_walk_claim() { fm_walk_marker claim "$@"; }
fm_walk_release() { fm_walk_marker release "$@"; }

fm_walk_meta_read() {
  local meta=$1 count
  FM_WALK_META_ID=$(fm_meta_get "$meta" walk_id)
  FM_WALK_META_OWNER=$(fm_meta_get "$meta" walk_owner)
  FM_WALK_META_TOKEN=$(fm_meta_get "$meta" walk_token)
  FM_WALK_META_EXPIRES=$(fm_meta_get "$meta" walk_expires_at)
  count=$(awk -F= '$1 ~ /^walk_(id|owner|token|expires_at)$/ { n[$1]++; total++ }
    END { if (!total) print 0; else if (n["walk_id"] == 1 && n["walk_owner"] == 1 && n["walk_token"] == 1 && n["walk_expires_at"] == 1) print 4; else print -1 }' "$meta") || return 1
  [ "$count" != 0 ] || return 0
  if [ "$count" != 4 ] || ! fm_walk_options_valid "$FM_WALK_META_ID" "$FM_WALK_META_OWNER" 1 \
    || ! [[ "$FM_WALK_META_TOKEN" =~ ^[0-9a-f]{16}$ ]] \
    || ! jq -en --arg expiry "$FM_WALK_META_EXPIRES" '
      $expiry | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
      and (try (($expiry | fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $expiry) catch false)
    ' >/dev/null 2>&1; then
    printf 'error: malformed walk claim in %s; retaining the record\n' "$meta" >&2
    return 1
  fi
}

fm_walk_release_meta() {
  local result
  fm_walk_meta_read "$1" || return 1
  [ -n "$FM_WALK_META_ID" ] || return 0
  if result=$(fm_walk_release "$FM_WALK_META_ID" "$FM_WALK_META_OWNER" "$FM_WALK_META_TOKEN" 2>&1); then
    return 0
  fi
  printf 'error: walk-marker release failed for %s (%s), expires_at=%s; retaining %s: %s\n' \
    "$FM_WALK_META_ID" "$FM_WALK_META_OWNER" "$FM_WALK_META_EXPIRES" "$1" "${result:0:300}" >&2
  return 1
}
