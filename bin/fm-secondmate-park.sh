#!/usr/bin/env bash
# Manage the persistent launch refusal for one secondmate.
#
# Usage: fm-secondmate-park.sh park <id>
#        fm-secondmate-park.sh unpark <id>
#        fm-secondmate-park.sh status <id>
#
# bin/fm-secondmate-park-lib.sh owns the record format and the shared refusal
# every relaunch path calls. This command owns publication and removal,
# including the remote mirror. park requires FM_HOME, a single path-segment
# id, and one registry line for that id in data/secondmates.md, then writes
# config/secondmate-parked/<id> atomically with today's UTC date.
# Parking again rewrites the date. unpark removes a regular record and is
# idempotent when the file is already absent. It refuses to follow or unlink
# a symlink. status prints the shared reason and exits 0 when parked, exits 1
# when no record exists, and exits 2 when the record is unsafe.
#
# Remote park and unpark require an acknowledged, generation-ordered mirror
# in the remote home. A failed acknowledgement retains the local park and
# returns failure. Generic config inheritance does not copy this directory.
# Local publication holds the per-home relaunch, per-task control and spawn,
# and remote inheritance transaction locks until the mirror is acknowledged.
# See docs/configuration.md "Owner park" for stopping an already-running mate.
#
# Exit status: 0 the verb succeeded (status: the mate is parked); 1 status
# found no record, park names an unregistered id, or an operational failure
# prevented confirmation; 2 invalid use or an unsafe record.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,/^[^#]/{/^#/{s/^# \{0,1\}//;p;};}' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-secondmate-park refuses to resolve a second mate without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }

DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-secondmate-park-lib.sh
. "$SCRIPT_DIR/fm-secondmate-park-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

verb=$1
shift
id=${1:-}
[ -n "$id" ] || { echo "error: $verb requires a secondmate id" >&2; usage >&2; exit 2; }
shift
case "$id" in
  ''|*[!A-Za-z0-9._-]*) echo "error: invalid secondmate id: $id" >&2; exit 2 ;;
esac

[ "$#" -eq 0 ] || { echo "error: unexpected argument '$1'" >&2; usage >&2; exit 2; }

park_dir="$CONFIG/secondmate-parked"
park_file="$park_dir/$id"

case "$verb" in
  park|unpark)
    STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    # shellcheck source=bin/fm-secondmate-nudge-lib.sh
    . "$SCRIPT_DIR/fm-secondmate-nudge-lib.sh"
    park_locks=()
    cleanup() {
      local i
      for ((i=${#park_locks[@]}-1; i>=0; i--)); do
        fm_lock_release "${park_locks[i]}" || true
      done
    }
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    remote_lock=$(fm_remote_inherit_transaction_lock_path "$STATE" "$id") || exit 1
    for lock in "$STATE/.secondmate-relaunch.lock" "$STATE/.control-$id.lock" \
      "$STATE/.spawn-$id.lock" "$remote_lock"; do
      fm_lock_acquire_wait "$lock" || { echo "error: could not lock $lock" >&2; exit 1; }
      park_locks+=("$lock")
    done
    ;;
esac

sync_remote_park() {
  local action=$1 payload=$2 remote generation bytes hash out
  remote=$(secondmate_registry_field "$DATA/secondmates.md" "$id" remote 2>/dev/null) || return 0
  [ "$remote" = 1 ] || return 0
  # shellcheck source=bin/fm-config-inherit-lib.sh
  . "$SCRIPT_DIR/fm-config-inherit-lib.sh"
  generation=$(fm_remote_inherit_generation_next "$STATE" "$id") || return 1
  bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ') || return 1
  hash=$(fm_inherit_sha256 "$payload") || return 1
  if ! out=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-on.sh" --stdin "$id" \
    fm-remote-inherit.sh "$action" "config/secondmate-parked/$id" "$bytes" "$hash" "$generation" < "$payload"); then
    echo "error: remote owner park $action for $id was not confirmed; local park retained" >&2
    return 1
  fi
  case "$action:$out" in
    "put:pushed: config/secondmate-parked/$id"|"put:unchanged: config/secondmate-parked/$id"|\
    "absent:removed: config/secondmate-parked/$id"|"absent:unchanged: config/secondmate-parked/$id") return 0 ;;
  esac
  echo "error: remote owner park $action for $id returned no publication confirmation; local park retained" >&2
  return 1
}

case "$verb" in
  park)
    secondmate_registry_line_for_id "$DATA/secondmates.md" "$id" || {
      echo "error: $id is not registered in $DATA/secondmates.md" >&2
      exit 1
    }
    date=$(date -u +%Y-%m-%d) || { echo "error: could not read today's UTC date" >&2; exit 1; }
    if [ -L "$park_dir" ]; then
      echo "error: $park_dir is a symlink; park refuses to follow it" >&2
      exit 2
    fi
    if [ -e "$park_dir" ] && [ ! -d "$park_dir" ]; then
      echo "error: $park_dir is not a directory" >&2
      exit 2
    fi
    if [ -L "$park_file" ]; then
      echo "error: $park_file is a symlink; park refuses to replace it" >&2
      exit 2
    fi
    if [ -e "$park_file" ] && [ ! -f "$park_file" ]; then
      echo "error: $park_file is not a regular file" >&2
      exit 2
    fi
    mkdir -p -- "$park_dir" || { echo "error: could not create $park_dir" >&2; exit 1; }
    chmod 700 "$park_dir" || { echo "error: could not set mode 0700 on $park_dir" >&2; exit 1; }
    tmp=$(mktemp "$park_dir/.owner-park.XXXXXX") || { echo "error: could not stage the park record" >&2; exit 1; }
    if ! chmod 600 "$tmp"; then
      rm -f -- "$tmp"
      echo "error: could not set mode 0600 on the park record" >&2
      exit 1
    fi
    if ! printf 'owner %s\n' "$date" > "$tmp"; then
      rm -f -- "$tmp"
      echo "error: could not write the park record" >&2
      exit 1
    fi
    if ! mv -f -- "$tmp" "$park_file"; then
      rm -f -- "$tmp"
      echo "error: could not publish the park record" >&2
      exit 1
    fi
    sync_remote_park put "$park_file" || exit 1
    printf 'parked: %s: owner %s\n' "$id" "$date"
    ;;
  unpark)
    if [ -L "$park_file" ]; then
      echo "error: $park_file is a symlink; unpark refuses to follow or remove it" >&2
      exit 2
    fi
    if [ ! -e "$park_file" ]; then
      sync_remote_park absent /dev/null || exit 1
      printf 'unparked: %s: already clear\n' "$id"
      exit 0
    fi
    if [ ! -f "$park_file" ]; then
      echo "error: $park_file is not a regular file; unpark refuses to remove it" >&2
      exit 2
    fi
    sync_remote_park absent /dev/null || exit 1
    rm -f -- "$park_file" || { echo "error: could not remove $park_file" >&2; exit 1; }
    printf 'unparked: %s\n' "$id"
    ;;
  status)
    if fm_secondmate_owner_parked "$CONFIG" "$id"; then
      printf '%s\n' "$FM_SECONDMATE_OWNER_PARK_REASON"
      [ "$FM_SECONDMATE_OWNER_PARK_CLASS" = parked ] && exit 0
      exit 2
    fi
    printf 'not parked: %s\n' "$id"
    exit 1
    ;;
  *)
    echo "error: unknown verb '$verb'" >&2
    usage >&2
    exit 2
    ;;
esac
