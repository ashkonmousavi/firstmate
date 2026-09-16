#!/usr/bin/env bash
# Install a filled secondmate nav-prep into this home's ship-prep path.
# Usage: fm-prep-install.sh <task-id> [--force]
#   Copies a filled preparation record into $FM_HOME/data/<task-id>/prep.md
#   (creating the task directory). Default source discovery walks each home=
#   path in data/secondmates.md and takes the first
#   <home>/data/nav-preps/<task-id>.md that passes fm_prep_unfilled_reason as
#   filled.
#   A destination that already passes the prep gate is refused unless --force.
#   Missing or unfilled destinations are replaced, including an empty local
#   --prep scaffold. This helper never auto-runs from spawn; spawn only names
#   a discovered filled nav-prep and this command.
#   Exits non-zero when no filled nav-prep is found.
# Environment:
#   FM_HOME              operational home whose data/ receives the install
#   FM_DATA_OVERRIDE     optional data directory; default $FM_HOME/data
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

FORCE=0
ID=
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --force) FORCE=1 ;;
    --)
      echo "error: usage: fm-prep-install.sh <task-id> [--force]" >&2
      exit 2
      ;;
    -*)
      echo "error: unknown flag $arg" >&2
      echo "usage: fm-prep-install.sh <task-id> [--force]" >&2
      exit 2
      ;;
    *)
      if [ -n "$ID" ]; then
        echo "error: usage: fm-prep-install.sh <task-id> [--force]" >&2
        exit 2
      fi
      ID=$arg
      ;;
  esac
done
if [ -z "$ID" ] || ! fm_pr_task_id_valid "$ID"; then
  echo "error: usage: fm-prep-install.sh <task-id> [--force]" >&2
  exit 2
fi

if [ ! -d "$DATA" ] || [ -L "$DATA" ]; then
  echo "error: data directory is unavailable: $DATA" >&2
  exit 1
fi

DEST=$(fm_prep_path "$DATA" "$ID")
REGISTRY="$DATA/secondmates.md"
SRC=

if ! SRC=$(fm_nav_prep_filled_source "$REGISTRY" "$ID"); then
  echo "error: no filled nav-prep for $ID (looked under each home= in $REGISTRY for data/nav-preps/$ID.md)" >&2
  exit 1
fi

if ! fm_prep_unfilled_reason "$DEST" >/dev/null; then
  if [ "$FORCE" -eq 0 ]; then
    echo "error: $DEST already passes the preparation gate; pass --force to overwrite" >&2
    exit 1
  fi
fi

mkdir -p "$DATA/$ID"
TMP=$(mktemp "$DATA/$ID/.prep.md.XXXXXX") || exit 1
trap 'rm -f -- "$TMP"' EXIT HUP INT TERM
cp "$SRC" "$TMP"
mv -f "$TMP" "$DEST"
TMP=
trap - EXIT HUP INT TERM
printf 'installed: %s (from %s)\n' "$DEST" "$SRC"
