#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh --help
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Apart from the owner-request custody path below, arguments
# reach tasks-axi as given, with a rewrite that preserves file arguments: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# Optional add/update --owner-request-file consumes a private interpreted packet,
# merges its protected section under this task's existing control lock, and
# verifies the native full-body readback. It is never forwarded to tasks-axi.
# Ordinary body edits to bound tasks preserve that section exactly.
# Packet authoring contract and exact PACKET/SOURCE/REQ/REF fields:
# bin/fm-request-acceptance.py's module header and validator below those fields.
# Example: fm-tasks-axi.sh add <id> '<title>' --owner-request-file <private-json-path>.
# Owner-request custody requires an explicit safe task ID; add/create --mint
# remains the ordinary unbound path and cannot take --owner-request-file.
# An exact packet retry confirms the existing native full body without another
# write; conflicting or unavailable confirmation refuses. Packet updates archive
# the prior body, preserving ordinary prose and earlier source/correction records.
#
# `show` (including `view`) and `list` decode stored captain-hold reasons
# through bin/fm-hold-reason-lib.sh, which owns the field-only decoding contract.
# Decoded reasons use quoted strings so embedded line breaks remain intact.
#
# Why it exists: a bare `tasks-axi` resolves the tracked `.tasks.toml` paths
# against its working directory, so from the code root it forks the queue
# whenever the home lives elsewhere; docs/configuration.md ("Backlog backend")
# owns that rationale.
#
# Addressing is bin/fm-backlog-transition-lib.sh's fm_backlog_tasks_axi_addressing,
# the same resolution the lifecycle transitions use: tasks-axi runs from the
# configured data directory's parent, so that home's own `.tasks.toml` (or
# tasks-axi's built-in defaults, which keep the archive beside the backlog)
# supplies the adapter, done_keep, and the archive path; a markdown backlog is
# additionally pinned to `<data>/backlog.md` through TASKS_AXI_FILE. The
# environment carries the pin rather than a trailing --file so the no-command
# dashboard works too. A configured non-markdown adapter is addressed by that
# root alone, so an inherited TASKS_AXI_FILE is cleared for it.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/ (FM_HOME unset keeps the single-home layout unchanged).
#
# Preflight refusals (exit 2, no tasks-axi mutation):
#   - tasks-axi missing from PATH;
#   - a caller-supplied --file, because this command owns the addressing and
#     tasks-axi would silently let the last --file win;
#   - `add` (or its `create` alias) with --start, so neither spelling places a
#     row In flight without the dispatch artifacts bin/fm-spawn.sh creates -
#     the task record, status file, and inbox that go with the row - which such
#     a row would lack, counting as live work nobody is doing that nothing
#     later would notice (`start <id>` stays a documented direct transition);
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/fm-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file.
# Custody failures also exit 2; a post-write failure leaves the write unconfirmed,
# so preserve the packet for exact readback confirmation rather than recreating it.
# Otherwise the exit status is tasks-axi's own, unless decoding a read fails;
# in that case the decoder's nonzero status is returned.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tasks-axi: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
OWNER_REQUEST_FILE=
OWNER_FLAG_SEEN=0
BODY_FILE=
BODY_LITERAL=
BODY_PRESENT=0
MINT=0
body_value_next=0
path_value_next=0
last_flag=
for arg in "$@"; do
  if [ "$body_value_next" = 1 ]; then
    BODY_LITERAL=$arg
    BODY_PRESENT=1
    ARGS+=("$arg")
    body_value_next=0
    continue
  fi
  if [ "$path_value_next" = 1 ]; then
    absolute=$(absolute_from_caller "$arg")
    if [ "$last_flag" = --owner-request-file ]; then
      OWNER_REQUEST_FILE=$absolute
    else
      ARGS+=("$absolute")
      [ "$last_flag" != --body-file ] || BODY_FILE=$absolute
    fi
    path_value_next=0
    continue
  fi
  case "$arg" in
    --mint)
      MINT=1
      ARGS+=("$arg")
      ;;
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
      ;;
    --start)
      case "${1:-}" in
        add|create)
          fail "add --start would place a row In flight with no dispatch record; add it Queued and let bin/fm-spawn.sh start it"
          ;;
      esac
      ARGS+=("$arg")
      ;;
    --body)
      ARGS+=("$arg")
      body_value_next=1
      ;;
    --body=*)
      ARGS+=("$arg")
      BODY_LITERAL=${arg#*=}
      BODY_PRESENT=1
      ;;
    --owner-request-file)
      [ "$OWNER_FLAG_SEEN" = 0 ] || fail "duplicate --owner-request-file"
      OWNER_FLAG_SEEN=1
      case "${1:-}" in add|create|update|edit) ;; *) fail "--owner-request-file is supported only by add/update" ;; esac
      path_value_next=1
      last_flag=$arg
      ;;
    --owner-request-file=*)
      [ "$OWNER_FLAG_SEEN" = 0 ] || fail "duplicate --owner-request-file"
      OWNER_FLAG_SEEN=1
      OWNER_REQUEST_FILE=$(absolute_from_caller "${arg#*=}")
      ;;
    --to|--*-file)
      last_flag=$arg
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      absolute=$(absolute_from_caller "${arg#*=}")
      ARGS+=("${arg%%=*}=$absolute")
      [ "${arg%%=*}" != --body-file ] || BODY_FILE=$absolute
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done
[ "$OWNER_FLAG_SEEN" = 0 ] || [ -n "$OWNER_REQUEST_FILE" ] || fail "--owner-request-file needs a private JSON path"
[ "$BODY_PRESENT" = 0 ] || [ -z "$BODY_FILE" ] || fail "choose one of --body or --body-file"

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA"; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi

if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
  if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
    fail "$FM_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
  fi
  export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
else
  unset TASKS_AXI_FILE
fi

cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"

# A control lock covers the full read/merge/write/readback span. Only explicit
# task IDs are accepted for this path; minted IDs have no prewrite lock identity.
case "${1:-}" in add|create|update|edit) mutation=1 ;; *) mutation=0 ;; esac
case "${1:-}" in
  add|create)
    if [ "$MINT" = 1 ]; then
      [ -z "$OWNER_REQUEST_FILE" ] || fail "owner request custody requires an explicit task id without --mint"
      exec tasks-axi "${ARGS[@]}"
    fi
    ;;
esac
if [ "$mutation" = 1 ] && { [ -n "$OWNER_REQUEST_FILE" ] || [ -n "$BODY_FILE" ] || [ "$BODY_PRESENT" = 1 ]; }; then
  ID=${2:-}
  case "$ID" in
    ''|*[!A-Za-z0-9._-]*)
      fail "body custody requires an explicit safe task id"
      ;;
  esac
  STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  mkdir -p -- "$STATE" || fail "cannot open task state directory"
  LOCK="$STATE/.control-$ID.lock"
  fm_lock_acquire_wait "$LOCK" || fail "cannot acquire task control lock"
  # shellcheck disable=SC2329 # EXIT trap invokes this function.
  cleanup_custody() {
    [ -z "${STAGED_BODY:-}" ] || rm -f -- "$STAGED_BODY"
    [ -z "${PRIOR_BODY:-}" ] || rm -f -- "$PRIOR_BODY"
    fm_lock_release "$LOCK" || true
  }
  trap cleanup_custody EXIT
  STAGED_BODY=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-request-body.XXXXXX") || fail "cannot stage request body"
  PRIOR_BODY=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-request-prior.XXXXXX") || fail "cannot stage prior body"
  operation=update
  case "${1:-}" in add|create) operation=add ;; esac
  if [ "$operation" = update ]; then
    shown=$(tasks-axi show "$ID" --full) || fail "native full task read failed"
    printf '%s\n' "$shown" | "$SCRIPT_DIR/fm-request-acceptance.py" show-body --task-id "$ID" > "$PRIOR_BODY" || fail "native task body could not be decoded"
  fi
  if [ -n "$OWNER_REQUEST_FILE" ]; then
    [ -f "$OWNER_REQUEST_FILE" ] && [ ! -L "$OWNER_REQUEST_FILE" ] || fail "request packet must be a regular private file"
    python3 - "$OWNER_REQUEST_FILE" <<'PYPACKET' || fail "request packet must be owned by this account and private"
import os, stat, sys
item = os.lstat(sys.argv[1])
sys.exit(0 if stat.S_ISREG(item.st_mode) and item.st_uid == os.geteuid() and item.st_mode & 0o077 == 0 else 1)
PYPACKET
    if [ -n "$BODY_FILE" ] || [ "$BODY_PRESENT" = 1 ]; then
      [ "$operation" != update ] || fail "owner update reads its current body; omit --body and --body-file"
      if [ -n "$BODY_FILE" ]; then cp -- "$BODY_FILE" "$PRIOR_BODY" || fail "cannot read original body";
      else printf '%s' "$BODY_LITERAL" > "$PRIOR_BODY" || fail "cannot stage original body"; fi
    fi
    "$SCRIPT_DIR/fm-request-acceptance.py" merge --body-file "$PRIOR_BODY" --packet-file "$OWNER_REQUEST_FILE" --task-id "$ID" --home "$FM_HOME" --operation "$operation" > "$STAGED_BODY" || fail "owner request packet refused"
  else
    if [ -n "$BODY_FILE" ]; then cp -- "$BODY_FILE" "$STAGED_BODY" || fail "cannot read candidate body";
    else printf '%s' "$BODY_LITERAL" > "$STAGED_BODY" || fail "cannot stage candidate body"; fi
    if [ "$operation" = update ]; then
      "$SCRIPT_DIR/fm-request-acceptance.py" compare-section --body-file "$PRIOR_BODY" --packet-file "$STAGED_BODY" --task-id "$ID" --home "$FM_HOME" || fail "bound acceptance section changed by ordinary edit"
    fi
  fi
  if [ "$operation" = add ] && [ -n "$OWNER_REQUEST_FILE" ]; then
    # An add may have landed before its readback failed. Only a complete
    # native show of this exact task body can confirm that prior write.
    if shown=$(tasks-axi show "$ID" --full 2>&1); then
      printf '%s\n' "$shown" | "$SCRIPT_DIR/fm-request-acceptance.py" compare-show --body-file "$STAGED_BODY" --task-id "$ID" --home "$FM_HOME" || fail "existing native task does not match owner request; no task write"
      printf 'ok: owner request already recorded for %s; no task write\n' "$ID"
      exit 0
    fi
    show_code=$(printf '%s\n' "$shown" | sed -n 's/^code: //p')
    [ "$show_code" = NOT_FOUND ] || fail "native task confirmation unavailable; no task write"
  fi
  if [ "$operation" = update ] && [ -n "$OWNER_REQUEST_FILE" ] && cmp -s "$PRIOR_BODY" "$STAGED_BODY"; then
    [ "${#ARGS[@]}" -eq 2 ] || fail "already recorded packet has unrelated update fields"
    printf '%s\n' "$shown" | "$SCRIPT_DIR/fm-request-acceptance.py" compare-show --body-file "$PRIOR_BODY" --task-id "$ID" --home "$FM_HOME" || fail "native no-op confirmation failed"
    printf 'ok: owner request already recorded for %s\n' "$ID"
    exit 0
  fi
  REWRITTEN=()
  skip=0
  for arg in "${ARGS[@]}"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$arg" in
      --body-file|--body) skip=1 ;;
      --body-file=*|--body=*) ;;
      *) REWRITTEN+=("$arg") ;;
    esac
  done
  REWRITTEN+=(--body-file "$STAGED_BODY")
  [ -z "$OWNER_REQUEST_FILE" ] || { [ "$operation" != update ] || REWRITTEN+=(--archive-body); }
  if [ "$operation" = add ] && [ -n "$OWNER_REQUEST_FILE" ]; then
    write_out=$(tasks-axi "${REWRITTEN[@]}" 2>&1) || fail "native task write failed"
    if printf '%s\n' "$write_out" | grep -Fxq 'already: true'; then
      fail "native add found an existing task after the absence read; write unconfirmed"
    fi
    printf '%s\n' "$write_out"
  else
    tasks-axi "${REWRITTEN[@]}" || fail "native task write failed"
  fi
  shown=$(tasks-axi show "$ID" --full) || fail "native full task readback failed; write unconfirmed"
  if [ -n "$OWNER_REQUEST_FILE" ]; then
    printf '%s\n' "$shown" | "$SCRIPT_DIR/fm-request-acceptance.py" compare-show --body-file "$STAGED_BODY" --task-id "$ID" --home "$FM_HOME" || fail "native request readback mismatch; write unconfirmed"
  else
    printf '%s\n' "$shown" | "$SCRIPT_DIR/fm-request-acceptance.py" show-body --task-id "$ID" > "$PRIOR_BODY" || fail "native body readback failed; write unconfirmed"
    python3 - "$STAGED_BODY" "$PRIOR_BODY" <<'PYBODY' || fail "native body readback mismatch; write unconfirmed"
import pathlib, sys
a, b = (pathlib.Path(p).read_bytes() for p in sys.argv[1:])
sys.exit(0 if a.rstrip(b"\n") == b else 1)
PYBODY
  fi
  exit 0
fi
case "${1:-}" in
  show|view|list)
    set -o pipefail
    tasks-axi ${ARGS[@]+"${ARGS[@]}"} | fm_hold_reason_decode_stream
    exit $?
    ;;
esac
exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
