#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's lint definition.
#
# Runs its file set with ShellCheck's default severity, extended analysis,
# ambient configuration disabled, and one exact ShellCheck version. CI and
# no-mistakes both invoke this script with no arguments, so the rule set,
# version, bounded execution, and diagnostics ordering cannot drift.
# The explicit --fast mode is local-only and disables ShellCheck's extended
# dataflow analysis while preserving ordinary shell lint checks. CI and
# no-mistakes keep the full-analysis no-argument default.
# Tests stop source analysis at imported production modules because every
# production shell is already a canonical, source-aware root of this same run.
# The default (no explicit-path) path also runs bin/fm-lint-workflows.sh so a
# malformed GitHub workflow, including a self-broken ci.yml, fails locally
# before merge instead of only failing to run as CI.
#
# With no explicit paths, the file set depends on context:
#   - In CI (GITHUB_ACTIONS=true or CI=true), on the main branch, or when no
#     merge-base against origin/main (or local main) can be found, it lints
#     the full canonical set: bin/*.sh bin/backends/*.sh tests/*.sh. This is
#     what CI always runs, so CI coverage never depends on a local diff.
#   - Otherwise (an ordinary local branch with a real merge-base) it lints
#     only the canonical-set files changed since that merge-base, including
#     uncommitted local edits, via plain local `git diff` (no network, no
#     `gh`). A branch with zero matching changed files skips ShellCheck and
#     prints a "no changed lint targets" note, then still validates workflows.
# Explicit paths always bypass this file-set selection and lint exactly the
# given paths, matching the same config, without the workflow YAML check.
#
# Execution is memory-bounded, not throughput-bounded: exactly one ShellCheck
# process at a time, and exactly one root file per invocation (FM_LINT_BATCH_SIZE).
#
# What actually costs memory here is one root's INLINED PROGRAM - the root plus
# everything --external-sources pulls in transitively - under extended dataflow
# analysis, and it grows far faster than that program's size. Measured on this
# tree with ShellCheck 0.11.0 on 2026-09-09:
#   bin/fm-spawn.sh      690 KB inlined   3.43 GB peak (242 MB with dataflow off)
#   bin/fm-teardown.sh   790 KB inlined  >6.5 GB peak (684 MB with dataflow off)
#   77 small roots       964 KB total     197 MB peak in ONE invocation
# The last row is why batching is not itself the accumulator: ShellCheck frees
# between roots, so a batch peaks at its worst root, not at their sum. The
# 2026-09-09 host exhaustion at 7.6 GB was two CONCURRENT shards each carrying
# one of those large roots at the same time.
#
# So the serial pipeline is what removes the multiplier that crashed the host,
# and one root per invocation is what makes the remaining peak attributable to a
# single named root instead of to whichever roots a scheduler happened to pair.
# That is why the batch size must stay 1 rather than being traded back for
# process startup.
#
# --external-sources is therefore not a blanket default. A root gets it only
# when it needs source resolution to be judged correctly, decided per file by
# fm_lint_needs_source_analysis below. Roots that source nothing are proven to
# produce byte-identical diagnostics either way, so the verdict is unchanged.
#
# One root per invocation is still not a bound, because a single root can be too
# large on its own. FM_LINT_MAX_CLOSURE_KB is that bound: a root whose inlined
# program exceeds it is analyzed WITHOUT source traversal, and the run says so on
# one labelled line naming the root and its closure size. Such a root keeps every
# ordinary shell check and loses cross-module dataflow; SC1091 is excluded for it
# alone, because sources this runner declined to load are a boundary it drew, not
# a defect in the root. The limit is one constant used identically in CI and
# locally, so the verdict cannot diverge between them.
#
# 320 KB is derived from measurement on this tree, as the point where the full
# path crosses about 1 GB: 313 KB -> 0.98 GB, 321 KB -> 1.03 GB, 327 KB -> 1.20 GB.
# It leaves 25 of 377 roots on the bounded path. Closure size is a good but not
# perfect predictor - 354 KB -> 0.81 GB and 395 KB -> 1.05 GB are low outliers -
# so treat the limit as calibrated, not exact, and re-derive it from fresh
# measurements rather than nudging it to make one root fit.
#
# The worker writes one diagnostics stream in deterministic root order and the
# parent replays it after the worker finishes. FM_LINT_JOBS / --jobs is still
# accepted and still validated as 1 or 2, but it no longer selects concurrency:
# both values run the same single serial pipeline with byte-identical
# diagnostics and exit selection.
#
# Optional quiet telemetry writes one bounded TSV snapshot of content and source
# graph identity, wall/CPU/RSS, batch bounds, and competing ShellCheck processes.
#
# Usage:
#   fm-lint.sh                         lint the context-selected file set (see above)
#   fm-lint.sh --fast [path]...       local lint with extended analysis disabled
#   fm-lint.sh <path>...               lint explicit roots with the same config
#   fm-lint.sh --jobs <1|2> [path]...  accepted for compatibility; always serial
#   fm-lint.sh --telemetry <path> ...  write a quiet metrics snapshot
#   fm-lint.sh --required-version      print the ShellCheck pin
#   fm-lint.sh --closure-limit-kb      print the source-closure limit in KB
#   fm-lint.sh --list-files            print the file set that would be linted
#   fm-lint.sh --help                  print this usage
set -u

# fm-lint.sh is routinely invoked by tooling from a non-interactive shell with
# no process group of its own (a worker's tool call, a background job).
# Without isolation, it inherits whatever ambient process group its caller
# happens to share with other processes, so that caller's own unrelated
# cleanup (a process-group-wide signal to reap stray background jobs after
# its own command finishes) can kill this script outright before it ever
# prints its real verdict. Re-exec once through perl's setpgrp so this script
# always owns its process group, the same isolation already given to each
# ShellCheck worker below. FM_LINT_ISOLATED is also set by fm_lint_run_worker
# for the private --internal-worker recursion, which is isolated by its
# caller before it ever reaches this script.
if [ "${FM_LINT_ISOLATED:-0}" != 1 ] && command -v perl >/dev/null 2>&1; then
  FM_LINT_ISOLATED=1 exec perl -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
    -- "${BASH:-bash}" "$0" "$@"
fi

REQUIRED_SHELLCHECK=0.11.0
# The one closure-size limit, identical in CI and locally so the verdict cannot
# diverge between them. See the memory contract in the header for how it was
# derived and what a root above it loses.
FM_LINT_MAX_CLOSURE_KB=320
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-lint.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
cd "$ROOT" || exit 1

FM_LINT_WORKER_SHELLCHECK_PID=
# shellcheck disable=SC2329 # Registered by the private worker's signal traps.
fm_lint_worker_stop() {
  [ -n "$FM_LINT_WORKER_SHELLCHECK_PID" ] || return 0
  kill "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  wait "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  FM_LINT_WORKER_SHELLCHECK_PID=
}

# fm_lint_needs_source_analysis <path>: true when a root can only be judged
# correctly with ShellCheck's source analysis. The test is deliberately loose -
# a source statement OR a `# shellcheck source=` directive, since neither
# implies the other in this tree - because the two error directions are not
# symmetric. Adding --external-sources to a root that sources nothing is a
# proven no-op on diagnostics; omitting it from a root that does source turns
# the verdict red with SC1091 and loses the suppressions the sourced context
# provides (SC2154 on a dependency-assigned variable, among others).
fm_lint_needs_source_analysis() {  # <path>
  LC_ALL=C grep -qE '^[[:space:]]*(\.|source)[[:space:]]|# shellcheck source=' -- "$1" 2>/dev/null
}

# fm_lint_source_closure_kb <path>: kilobytes of the program ShellCheck would
# load for this root under --external-sources - the root itself plus every file
# reachable through `# shellcheck source=` directives, transitively, with
# /dev/null boundaries excluded. That inlined program, not the root's own size,
# is what the peak tracks, so it is what FM_LINT_MAX_CLOSURE_KB gates on.
fm_lint_source_closure_kb() {  # <path>
  local root=$1 file dir target bytes total=0 seen=
  local -a queue
  queue=("$root")
  while [ "${#queue[@]}" -gt 0 ]; do
    file=${queue[0]}
    queue=(${queue[@]+"${queue[@]:1}"})
    case "$seen" in *"|$file|"*) continue ;; esac
    seen="$seen|$file|"
    [ -f "$file" ] || continue
    bytes=$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
    case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
    total=$((total + bytes))
    dir=${file%/*}
    [ "$dir" != "$file" ] || dir=.
    while IFS= read -r target; do
      [ -n "$target" ] && [ "$target" != /dev/null ] || continue
      if [ -f "$target" ]; then
        queue+=("$target")
      elif [ -f "$dir/$target" ]; then
        queue+=("$dir/$target")
      fi
    done < <(awk '
      /^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]+source=/ {
        line = $0
        sub(/^.*source=/, "", line)
        sub(/[[:space:]].*$/, "", line)
        if (line != "") { print line }
      }
    ' "$file")
  done
  printf '%s\n' "$((total / 1024))"
}

fm_lint_worker() {  # <manifest> <output-dir> <shard-index>
  local manifest=$1 output_dir=$2 shard_index=$3 tab index path output rc=0 file_rc closure_kb
  local -a roots shellcheck_args
  roots=()
  tab=$(printf '\t')
  while IFS="$tab" read -r index path || [ -n "${index:-}${path:-}" ]; do
    [ -n "${index:-}" ] || continue
    roots+=("$path")
  done < "$manifest"
  output="$output_dir/shard.$shard_index"
  : > "$output.out"
  trap 'fm_lint_worker_stop; exit 129' HUP
  trap 'fm_lint_worker_stop; exit 130' INT
  trap 'fm_lint_worker_stop; exit 143' TERM
  # One root per invocation, appended in manifest order, and never two
  # ShellCheck processes at once: this loop is the memory bound documented in
  # the header. Do not batch roots back together to save process startup.
  for path in ${roots[@]+"${roots[@]}"}; do
    shellcheck_args=(--norc)
    if [ "${FM_LINT_INTERNAL_FAST:-0}" -eq 1 ]; then
      shellcheck_args+=(--extended-analysis=false)
    fi
    if fm_lint_needs_source_analysis "$path"; then
      closure_kb=$(fm_lint_source_closure_kb "$path")
      if [ "$closure_kb" -gt "$FM_LINT_MAX_CLOSURE_KB" ]; then
        # Bounded root: its inlined program is too large to analyze whole, so
        # stop source traversal here. SC1091 is excluded for this root only,
        # because sources this runner deliberately declined to load are not a
        # defect in the root - the same boundary the tree already draws with
        # `# shellcheck source=/dev/null`. Every other check still runs.
        shellcheck_args+=(--exclude=SC1091)
        printf 'fm-lint.sh: bounded root %s (source closure %s KB exceeds the %s KB limit): source traversal stopped, so cross-module dataflow is not analyzed for this root and SC1091 is excluded for it.\n' \
          "$path" "$closure_kb" "$FM_LINT_MAX_CLOSURE_KB" >> "$output.out"
      else
        shellcheck_args+=(--external-sources)
      fi
    fi
    file_rc=0
    "$FM_LINT_SHELLCHECK" "${shellcheck_args[@]}" -- "$path" >> "$output.out" 2>&1 </dev/null &
    FM_LINT_WORKER_SHELLCHECK_PID=$!
    wait "$FM_LINT_WORKER_SHELLCHECK_PID" || file_rc=$?
    FM_LINT_WORKER_SHELLCHECK_PID=
    [ "$rc" -ne 0 ] || rc=$file_rc
  done
  trap - HUP INT TERM
  printf '%s\n' "$rc" > "$output.rc"
  return "$rc"
}

# Private subprocess mode used only by the bounded parent above.
if [ "${1:-}" = "--internal-worker" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-worker is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -eq 4 ] && [ -n "${FM_LINT_SHELLCHECK:-}" ] || exit 2
  fm_lint_worker "$2" "$3" "$4"
  exit $?
fi

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

if [ "${1:-}" = "--closure-limit-kb" ]; then
  printf '%s\n' "$FM_LINT_MAX_CLOSURE_KB"
  exit 0
fi

fm_lint_usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

# Default no-args lint also validates GitHub workflows. Explicit paths stay a
# ShellCheck-only override so callers can target one shell root.
fm_lint_run_workflows() {
  [ "$EXPLICIT_PATHS" -eq 0 ] || return 0
  "$SELF_DIR/fm-lint-workflows.sh"
}

JOBS=${FM_LINT_JOBS:-2}
TELEMETRY=${FM_LINT_TELEMETRY:-}
FAST=0
ANALYSIS_MODE=full
LIST_FILES=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --jobs requires 1 or 2.\n' >&2; exit 2; }
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#*=}
      shift
      ;;
    --telemetry)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --telemetry requires a path.\n' >&2; exit 2; }
      TELEMETRY=$2
      shift 2
      ;;
    --telemetry=*)
      TELEMETRY=${1#*=}
      shift
      ;;
    --fast)
      FAST=1
      ANALYSIS_MODE=fast
      shift
      ;;
    --list-files)
      LIST_FILES=1
      shift
      ;;
    --help|-h)
      fm_lint_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done

case "$JOBS" in
  1|2) ;;
  *) printf 'fm-lint.sh: jobs must be 1 or 2, got %s.\n' "$JOBS" >&2; exit 2 ;;
esac

if [ "$FAST" -eq 1 ] && { [ "${GITHUB_ACTIONS:-}" = true ] || [ "${CI:-}" = true ]; }; then
  printf 'fm-lint.sh: --fast is local-only; CI uses full ShellCheck analysis.\n' >&2
  exit 2
fi

# fm_lint_changed_base_ref prints the ref to diff the working branch against:
# the local origin/main tracking ref when present, else local main. Returns
# nonzero when neither is resolvable, which the caller treats as "no
# merge-base found" and falls back to a full lint.
fm_lint_changed_base_ref() {
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    printf 'origin/main\n'
    return 0
  fi
  if git rev-parse --verify -q main >/dev/null 2>&1; then
    printf 'main\n'
    return 0
  fi
  return 1
}

# fm_lint_is_canonical_root tests membership in the canonical set (a direct
# *.sh child of bin/, bin/backends/, or tests/) without the shell case
# statement's non-pathname wildcard matching a path separator by accident.
fm_lint_is_canonical_root() {
  local path=$1 dir base
  case "$path" in
    */*) dir=${path%/*}; base=${path##*/} ;;
    *) dir=; base=$path ;;
  esac
  case "$base" in
    *.sh) : ;;
    *) return 1 ;;
  esac
  case "$dir" in
    bin|bin/backends|tests) return 0 ;;
    *) return 1 ;;
  esac
}

CHANGED_MODE=0
EXPLICIT_PATHS=0
if [ "$#" -gt 0 ]; then
  EXPLICIT_PATHS=1
  ROOTS=("$@")
else
  full_lint=1
  if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${CI:-}" != true ] \
    && command -v git >/dev/null 2>&1 \
    && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != main ]; then
    base_ref=$(fm_lint_changed_base_ref) || base_ref=
    merge_base=
    [ -z "$base_ref" ] || merge_base=$(git merge-base "$base_ref" HEAD 2>/dev/null) || merge_base=
    [ -z "$merge_base" ] || full_lint=0
  fi

  if [ "$full_lint" -eq 1 ]; then
    ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh)
  else
    CHANGED_MODE=1
    ROOTS=()
    while IFS= read -r -d '' changed_path; do
      fm_lint_is_canonical_root "$changed_path" || continue
      [ -f "$changed_path" ] || continue
      ROOTS+=("$changed_path")
    done < <(git diff --name-only --diff-filter=ACMR -z "$merge_base" -- 2>/dev/null | LC_ALL=C sort -z)
  fi
fi
ROOT_COUNT=${#ROOTS[@]}

if [ "$LIST_FILES" -eq 1 ]; then
  [ "$#" -eq 0 ] || {
    printf 'fm-lint.sh: --list-files does not accept explicit paths.\n' >&2
    exit 2
  }
  [ "$ROOT_COUNT" -eq 0 ] || printf '%s\n' "${ROOTS[@]}"
  exit 0
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'fm-lint.sh: ShellCheck not found; install ShellCheck %s with bin/fm-install-shellcheck.sh <destination-directory> and put that directory on PATH.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
unset SHELLCHECK_OPTS
SHELLCHECK_BIN=$(command -v shellcheck)
if ! PERL_BIN=$(command -v perl); then
  printf 'fm-lint.sh: perl is required for bounded worker cleanup.\n' >&2
  exit 127
fi
resolved=$("$SHELLCHECK_BIN" --version | awk '/^version:/ {print $2; exit}')
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s with bin/fm-install-shellcheck.sh <destination-directory>.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
if [ "$FAST" -eq 1 ]; then
  printf 'fm-lint.sh: fast local mode; ShellCheck extended analysis disabled\n' >&2
else
  printf 'fm-lint.sh: full ShellCheck extended analysis enabled\n' >&2
fi

if [ "$CHANGED_MODE" -eq 1 ] && [ "$ROOT_COUNT" -eq 0 ]; then
  printf 'fm-lint.sh: no changed lint targets\n'
  overall_rc=0
  fm_lint_run_workflows || overall_rc=$?
  exit "$overall_rc"
fi

if [ -n "$TELEMETRY" ]; then
  telemetry_parent=$(dirname "$TELEMETRY")
  [ -d "$telemetry_parent" ] || {
    printf 'fm-lint.sh: telemetry directory does not exist: %s\n' "$telemetry_parent" >&2
    exit 2
  }
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint.XXXXXX") || exit 1
ACTIVE_PIDS=()
# shellcheck disable=SC2329 # Registered by the EXIT and signal traps below.
fm_lint_cleanup() {
  local pid
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_ROOT"
}
trap fm_lint_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

TAB=$(printf '\t')
OUTPUT_DIR="$TMP_ROOT/output"
mkdir -p "$OUTPUT_DIR"
# One serial pipeline, so one manifest. There is no load balancer any more:
# balancing only existed to keep two concurrent workers busy, and concurrency
# is exactly what the memory bound in the header removes.
SHARD_COUNT=1
BATCH_SIZE=1
: > "$TMP_ROOT/manifest.0"

index=1
for path in "${ROOTS[@]}"; do
  case "$path" in
    *"$TAB"*|*$'\n'*)
      printf 'fm-lint.sh: paths containing tabs or newlines are not supported: %s\n' "$path" >&2
      exit 2
      ;;
  esac
  printf '%s\t%s\n' "$index" "$path" >> "$TMP_ROOT/manifest.0"
  index=$((index + 1))
done

fm_lint_shellcheck_count() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x shellcheck 2>/dev/null | wc -l | tr -d '[:space:]'
  else
    printf 'unavailable'
  fi
}

fm_lint_load_average() {
  if [ -r /proc/loadavg ]; then
    awk '{print $1 "/" $2 "/" $3}' /proc/loadavg
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1 "/" $2 "/" $3}' || printf 'unavailable'
  else
    printf 'unavailable'
  fi
}

fm_lint_aggregate_cpu() {
  ps -A -o %cpu= 2>/dev/null | awk '{sum += $1} END {printf "%.2f", sum + 0}'
}

TELEMETRY_START_EPOCH=0
TELEMETRY_SHELLCHECK_START=unavailable
TELEMETRY_LOAD_START=unavailable
TELEMETRY_CPU_START=unavailable
if [ -n "$TELEMETRY" ]; then
  TELEMETRY_START_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_START=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_START=$(fm_lint_load_average)
  TELEMETRY_CPU_START=$(fm_lint_aggregate_cpu)
fi

fm_lint_run_worker() {  # <worker-index>
  local worker_index=$1 manifest timing
  manifest="$TMP_ROOT/manifest.$worker_index"
  timing="$TMP_ROOT/timing.$worker_index"
  if [ -n "$TELEMETRY" ] && [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -lp -o "$timing" \
        env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" FM_LINT_ISOLATED=1 \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    else
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -f 'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\nmax_rss_kib=%M' -o "$timing" \
        env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" FM_LINT_ISOLATED=1 \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    fi
  else
    [ -z "$TELEMETRY" ] || printf 'timing_unavailable=1\n' > "$timing"
    exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
      env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" FM_LINT_ISOLATED=1 \
      "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
  fi
}

fm_lint_start_worker() {
  fm_lint_run_worker "$1" &
  ACTIVE_PIDS+=("$!")
}

fm_lint_wait_workers() {
  local pid
  while [ "${#ACTIVE_PIDS[@]}" -gt 0 ]; do
    pid=${ACTIVE_PIDS[0]}
    wait "$pid" 2>/dev/null || true
    ACTIVE_PIDS=("${ACTIVE_PIDS[@]:1}")
  done
}

# JOBS is validated but never starts a second worker: both accepted values run
# this same one-worker pipeline, and the worker itself runs one ShellCheck at a
# time. See the memory contract in the header before reintroducing parallelism.
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  fm_lint_start_worker "$worker"
  fm_lint_wait_workers
  worker=$((worker + 1))
done

# Replay the worker's diagnostics in deterministic root order and select the
# first nonzero status. The worker runs every root regardless of earlier findings.
overall_rc=0
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  output="$OUTPUT_DIR/shard.$worker"
  [ ! -f "$output.out" ] || cat "$output.out"
  if [ -f "$output.rc" ]; then
    rc=$(cat "$output.rc" 2>/dev/null || printf '2')
    case "$rc" in ''|*[!0-9]*) rc=2 ;; esac
  else
    printf 'fm-lint.sh: worker produced no result for shard %s.\n' "$worker" >&2
    rc=2
  fi
  if [ "$overall_rc" -eq 0 ] && [ "$rc" -ne 0 ]; then
    overall_rc=$rc
  fi
  worker=$((worker + 1))
done

if [ -n "$TELEMETRY" ]; then
  TELEMETRY_END_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_END=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_END=$(fm_lint_load_average)
  TELEMETRY_CPU_END=$(fm_lint_aggregate_cpu)

  direct_lines=$(awk 'END {print NR + 0}' "${ROOTS[@]}" 2>/dev/null || printf 'unavailable')
  direct_bytes=0
  : > "$TMP_ROOT/content-cksums"
  : > "$TMP_ROOT/source-targets"
  source_directives=0
  source_boundaries=0
  for path in "${ROOTS[@]}"; do
    if [ -f "$path" ]; then
      bytes=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
      case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
      direct_bytes=$((direct_bytes + bytes))
      cksum "$path" >> "$TMP_ROOT/content-cksums" 2>/dev/null || true
      awk '
        /^[[:space:]]*# shellcheck source=/ {
          target=$0
          sub(/^[[:space:]]*# shellcheck source=/, "", target)
          sub(/[[:space:]].*$/, "", target)
          print target
        }
      ' "$path" >> "$TMP_ROOT/source-targets"
    fi
  done
  source_directives=$(wc -l < "$TMP_ROOT/source-targets" | tr -d '[:space:]')
  source_boundaries=$(grep -c '^/dev/null$' "$TMP_ROOT/source-targets" 2>/dev/null || true)
  case "$source_boundaries" in ''|*[!0-9]*) source_boundaries=0 ;; esac
  source_followed=$((source_directives - source_boundaries))
  source_targets=$(LC_ALL=C sort -u "$TMP_ROOT/source-targets" | wc -l | tr -d '[:space:]')
  content_cksum=$(cksum "$TMP_ROOT/content-cksums" | awk '{print $1 "-" $2}')
  git_head=$(git rev-parse HEAD 2>/dev/null || printf 'unavailable')

  if [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      timing_summary=$(awk '
        /^real / {wall += $2; if ($2 > max_wall) max_wall=$2}
        /^user / {user += $2}
        /^sys / {sys_cpu += $2}
        /maximum resident set size/ {
          rss=$1 / 1024
          rss_sum += rss
          if (rss > max_rss) max_rss=rss
        }
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    else
      timing_summary=$(awk -F= '
        $1 == "wall_seconds" {wall += $2; if ($2 > max_wall) max_wall=$2}
        $1 == "user_seconds" {user += $2}
        $1 == "system_seconds" {sys_cpu += $2}
        $1 == "max_rss_kib" {rss_sum += $2; if ($2 > max_rss) max_rss=$2}
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    fi
    read -r timing_user timing_system timing_worker_wall max_worker_rss worker_rss_sum max_worker_wall <<EOF
$timing_summary
EOF
  else
    timing_user=unavailable
    timing_system=unavailable
    timing_worker_wall=unavailable
    max_worker_rss=unavailable
    worker_rss_sum=unavailable
    max_worker_wall=unavailable
  fi

  telemetry_tmp="$TMP_ROOT/telemetry.tsv"
  {
    printf 'format\tfm-lint-telemetry-v1\n'
    printf 'git_head\t%s\n' "$git_head"
    printf 'content_cksum\t%s\n' "$content_cksum"
    printf 'shellcheck_version\t%s\n' "$resolved"
    printf 'analysis_mode\t%s\n' "$ANALYSIS_MODE"
    printf 'jobs\t%s\n' "$JOBS"
    printf 'root_count\t%s\n' "$ROOT_COUNT"
    printf 'direct_lines\t%s\n' "$direct_lines"
    printf 'direct_bytes\t%s\n' "$direct_bytes"
    printf 'source_directives\t%s\n' "$source_directives"
    printf 'source_boundary_directives\t%s\n' "$source_boundaries"
    printf 'source_followed_directives\t%s\n' "$source_followed"
    printf 'source_target_count\t%s\n' "$source_targets"
    printf 'batch_size\t%s\n' "$BATCH_SIZE"
    printf 'max_concurrent_shellcheck\t%s\n' "$SHARD_COUNT"
    printf 'wall_seconds\t%s\n' "$((TELEMETRY_END_EPOCH - TELEMETRY_START_EPOCH))"
    printf 'worker_wall_sum_seconds\t%s\n' "$timing_worker_wall"
    printf 'max_worker_wall_seconds\t%s\n' "$max_worker_wall"
    printf 'user_seconds\t%s\n' "$timing_user"
    printf 'system_seconds\t%s\n' "$timing_system"
    printf 'max_worker_rss_kib\t%s\n' "$max_worker_rss"
    printf 'worker_rss_sum_kib\t%s\n' "$worker_rss_sum"
    printf 'shellcheck_processes_start\t%s\n' "$TELEMETRY_SHELLCHECK_START"
    printf 'shellcheck_processes_end\t%s\n' "$TELEMETRY_SHELLCHECK_END"
    printf 'load_average_start\t%s\n' "$TELEMETRY_LOAD_START"
    printf 'load_average_end\t%s\n' "$TELEMETRY_LOAD_END"
    printf 'aggregate_cpu_percent_start\t%s\n' "$TELEMETRY_CPU_START"
    printf 'aggregate_cpu_percent_end\t%s\n' "$TELEMETRY_CPU_END"
    printf 'result_exit\t%s\n' "$overall_rc"
  } > "$telemetry_tmp"
  if ! mv -f "$telemetry_tmp" "$TELEMETRY"; then
    printf 'fm-lint.sh: could not write telemetry to %s.\n' "$TELEMETRY" >&2
    [ "$overall_rc" -ne 0 ] || overall_rc=2
  fi
fi

if [ "$overall_rc" -eq 0 ]; then
  fm_lint_run_workflows || overall_rc=$?
else
  fm_lint_run_workflows || true
fi

exit "$overall_rc"
