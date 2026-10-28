#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh --help
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Arguments reach tasks-axi as given, apart from one
# rewrite that keeps file arguments meaning what the caller meant: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# `show` (including `view`) and `list` decode stored captain-hold reasons
# through bin/fm-hold-reason-lib.sh, which owns the field-only decoding contract.
# Decoded reasons use quoted strings so embedded line breaks remain intact.
#
# HOLD RELEASE CONDITIONS. `hold` accepts one extra flag this wrapper owns,
# `--release-on pr:<owner>/<repo>#<n>` or `--release-on marker:<absolute-path>`:
# the condition is recorded beside the hold (state/hold-releases/<id>) and
# evaluated by the watcher's check sweep, which wakes firstmate once with
# `hold condition met: <id> <condition>` and keeps a keyed decision open in
# OPEN DECISIONS until the hold is released or re-held
# (bin/fm-hold-release-lib.sh owns the whole contract). A hold of kind
# external, or with no kind, with neither --release-on nor --until is refused, so each such
# hold always names when it clears. `unhold` drops the record and closes any
# still-open hold-release decision. The flag never reaches tasks-axi itself,
# and it is refused on every other command.
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
# Refusals (exit 2, nothing run):
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
# shellcheck source=bin/fm-hold-release-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-hold-release-lib.sh"

HOLD_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

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

# Pre-scan of the caller's own arguments for the hold/unhold bookkeeping
# facts this wrapper needs (id, kind, date gate, release condition). It
# changes nothing about the ARGS rewrite below, which keeps its own contract;
# the first argument is the command word and is skipped.
subcommand=${1:-}
first_positional=
hold_kind=
hold_until=
hold_release_on=
prescan_next=
help_requested=0
prescan_skip=1
for arg in "$@"; do
  if [ "$prescan_skip" = 1 ]; then
    prescan_skip=0
    continue
  fi
  if [ -n "$prescan_next" ]; then
    case "$prescan_next" in
      kind) hold_kind=$arg ;;
      until) hold_until=$arg ;;
      release-on) hold_release_on=$arg ;;
    esac
    prescan_next=
    continue
  fi
  case "$arg" in
    -h|--help) help_requested=1 ;;
    --reason) prescan_next=reason ;;
    --kind) prescan_next=kind ;;
    --until) prescan_next=until ;;
    --release-on)
      case "$subcommand" in
        hold) prescan_next=release-on ;;
        *)
          fail "--release-on is a hold flag; it names when a held row clears and is valid only on hold"
          ;;
      esac
      ;;
    --kind=*) hold_kind=${arg#--kind=} ;;
    --until=*) hold_until=${arg#--until=} ;;
    --release-on=*)
      case "$subcommand" in
        hold) hold_release_on=${arg#--release-on=} ;;
        *)
          fail "--release-on is a hold flag; it names when a held row clears and is valid only on hold"
          ;;
      esac
      ;;
    -*) : ;;
    *) [ -n "$first_positional" ] || first_positional=$arg ;;
  esac
done

ARGS=()
path_value_next=0
release_value_next=0
for arg in "$@"; do
  if [ "$release_value_next" = 1 ]; then
    # The --release-on value is this wrapper's own token and never reaches
    # tasks-axi; it is a condition, not a path, so it is dropped as given.
    release_value_next=0
    continue
  fi
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
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
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    --release-on|--release-on=*)
      # Validated by the prescan above; consumed here so tasks-axi never sees
      # this wrapper's own flag.
      case "$arg" in
        --release-on) release_value_next=1 ;;
      esac
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

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
if [ "$help_requested" = 1 ]; then
  exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
fi
case "$subcommand" in
  hold)
    # Kindless and kind-external holds always name when they clear.
    if { [ "$hold_kind" = external ] || [ -z "$hold_kind" ]; } && [ -z "$hold_until" ] && [ -z "$hold_release_on" ]; then
      fail "a kindless or external hold needs --release-on pr:<owner>/<repo>#<n> or --release-on marker:<absolute-path>, or --until <date>, so its clearing is checkable"
    fi
    if [ -n "$hold_release_on" ]; then
      fm_hold_release_valid "$hold_release_on" >/dev/null \
        || fail "--release-on must be pr:<owner>/<repo>#<n> or marker:<absolute-path>: $hold_release_on"
    fi
    ;;
esac
case "$subcommand" in
  hold|unhold)
    hold_mutation() {
      tasks-axi ${ARGS[@]+"${ARGS[@]}"}
      axi_rc=$?
      [ "$axi_rc" -eq 0 ] || return "$axi_rc"
      case "$subcommand" in
        hold)
          if [ -n "$hold_release_on" ]; then
            fm_hold_release_record_write "$HOLD_STATE" "$first_positional" "$hold_release_on" \
              || fail "the hold was recorded but its release condition could not be stored; re-run the same hold to retry"
          elif [ -e "$(fm_hold_release_record_path "$HOLD_STATE" "$first_positional")" ] \
            || [ -L "$(fm_hold_release_record_path "$HOLD_STATE" "$first_positional")" ]; then
            fm_hold_release_record_drop "$HOLD_STATE" "$first_positional" \
              "re-held without a structured release condition" \
              || printf 'fm-tasks-axi: warning: the hold was re-held but its stale release record could not be dropped\n' >&2
          fi
          ;;
        unhold)
          if [ -e "$(fm_hold_release_record_path "$HOLD_STATE" "$first_positional")" ] \
            || [ -L "$(fm_hold_release_record_path "$HOLD_STATE" "$first_positional")" ]; then
            fm_hold_release_record_drop "$HOLD_STATE" "$first_positional" "released" \
              || printf 'fm-tasks-axi: warning: the hold was released but its release record could not be dropped\n' >&2
          fi
          ;;
      esac
    }
    fm_hold_release_with_lock "$HOLD_STATE" "$first_positional" hold_mutation
    exit $?
    ;;
  show|view|list)
    set -o pipefail
    tasks-axi ${ARGS[@]+"${ARGS[@]}"} | fm_hold_reason_decode_stream
    exit $?
    ;;
esac
exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
