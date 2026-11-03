#!/usr/bin/env bash
# Park or unpark one persistent secondmate so relaunch leaves it stopped.
#
# Usage: fm-secondmate-park.sh park <id>
#        fm-secondmate-park.sh unpark <id>
#        fm-secondmate-park.sh status <id>
#
# bin/fm-secondmate-park-lib.sh owns the record format and the shared refusal
# every relaunch path calls. This command is the only writer and the only
# remover. park requires FM_HOME, a single path-segment id, and one registry
# line for that id in data/secondmates.md, then writes
# config/secondmate-parked/<id> atomically with today's UTC date.
# Parking again rewrites the date. unpark removes a regular record and is
# idempotent when the file is already absent. It refuses to follow or unlink
# a symlink. status prints the shared reason and exits 0 when parked, exits 1
# when no record exists, and exits 2 when the record is unsafe.
#
# The directory is not inherited. Copying it into a secondmate home would not
# be what the primary's relaunch paths read.
#
# Exit status: 0 the verb succeeded (status: the mate is parked); 1 status
# found no record, or park names an id this home does not register; 2 invalid
# use or an unsafe record.
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
  park)
    secondmate_registry_line_for_id "$DATA/secondmates.md" "$id" || {
      echo "error: $id is not registered in $DATA/secondmates.md" >&2
      exit 1
    }
    date=$(date -u +%Y-%m-%d) || { echo "error: could not read today's UTC date" >&2; exit 1; }
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
    printf 'parked: %s: owner %s\n' "$id" "$date"
    ;;
  unpark)
    if [ -L "$park_file" ]; then
      echo "error: $park_file is a symlink; unpark refuses to follow or remove it" >&2
      exit 2
    fi
    if [ ! -e "$park_file" ]; then
      printf 'unparked: %s: already clear\n' "$id"
      exit 0
    fi
    if [ ! -f "$park_file" ]; then
      echo "error: $park_file is not a regular file; unpark refuses to remove it" >&2
      exit 2
    fi
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
