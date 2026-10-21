#!/usr/bin/env bash
# Shared machine lane facts and admission. No side effects on source.
# Requires fm-wake-lib.sh, fm-backend.sh, fm-secondmate-registry-lib.sh and
# fm-project-capacity-lib.sh. fm-capacity.sh is the public report/publish API.
#
# config/lane-capacity in the local root home is mandatory: one line with
# <lane-ceiling> <memory-reserve-gb>, both non-negative integers (up to 6 digits).
# GB here means 1024^3 bytes. Zero ceiling stops admission; zero reserve allows
# zero MemAvailable. MemAvailable minus reserve must be >= 0. There are no
# per-lane estimates and CPU load never refuses admission.
# Every local registered home is counted through fm_local_firstmate_state_dirs.
# Task records hold a lane unless the endpoint is proven agent-free and the
# worktree has no non-shell process. Unknown liveness counts. Secondmates and
# records with pr= handoffs are exempt. External bots have no local records;
# ordinary local workers carrying walk markers still hold a lane.
# Unreadable config, state, registry or MemAvailable fails closed with exit 75.
# fm-spawn holds the root state's .machine-lane-capacity.lock from this read
# through record publication; reporting is advisory and never locks.

fm_capacity_read() { # <home> <config> <state> [replaced-task-id]
  local home=$1 config=$2 state=$3 self=${4:-} config_dir raw ceiling reserve extra
  local dir meta kind available meminfo=/proc/meminfo
  local backend target worktree processes line pid path holds name args argv0
  FM_CAPACITY_ERROR='' FM_CAPACITY_REASON=unreadable
  FM_CAPACITY_LANES=0 FM_CAPACITY_SECONDMATES=0 FM_CAPACITY_FREE=0
  FM_CAPACITY_TARGET=0 FM_CAPACITY_RESERVE_KB=0 FM_CAPACITY_AVAILABLE_KB=0 FM_CAPACITY_HEADROOM_KB=0
  FM_CAPACITY_FILE="$config/lane-capacity"
  config_dir=$(fm_project_capacity_config_dir "$home" "$config") || {
    FM_CAPACITY_ERROR="cannot resolve machine root for $home ($FM_CAPACITY_FILE)"; return 75;
  }
  FM_CAPACITY_FILE="$config_dir/lane-capacity"
  if [ ! -f "$FM_CAPACITY_FILE" ] || [ ! -r "$FM_CAPACITY_FILE" ]; then
    FM_CAPACITY_ERROR="$FM_CAPACITY_FILE is missing or unreadable"; return 75
  fi
  raw=$(cat -- "$FM_CAPACITY_FILE") || {
    FM_CAPACITY_ERROR="cannot read $FM_CAPACITY_FILE"; return 75;
  }
  # Reject embedded newlines as well as extra fields, signs and oversized values.
  IFS=' ' read -r ceiling reserve extra <<< "$raw"
  if [[ "$raw" == *$'\n'* ]] || ! [[ "$ceiling" =~ ^[0-9]{1,6}$ && "$reserve" =~ ^[0-9]{1,6}$ ]] || [ -n "$extra" ]; then
    FM_CAPACITY_ERROR="$FM_CAPACITY_FILE reading '$raw': expected <lane-ceiling> <memory-reserve-gb>"; return 75
  fi
  FM_CAPACITY_TARGET=$((10#$ceiling))
  FM_CAPACITY_RESERVE_KB=$((10#$reserve * 1048576))
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then meminfo=${FM_CAPACITY_MEMINFO:-/proc/meminfo}; fi
  available=$(awk '
    /^MemAvailable:/ { n++; if (NF == 3 && $2 ~ /^[0-9]+$/ && length($2) <= 13 && $3 == "kB") value=$2; else bad=1 }
    END { if (n != 1 || bad) exit 1; print value }
  ' "$meminfo" 2>/dev/null) || {
    FM_CAPACITY_ERROR="$meminfo: MemAvailable reading missing, malformed or unreadable"; return 75;
  }
  FM_CAPACITY_AVAILABLE_KB=$((10#$available))
  FM_CAPACITY_HEADROOM_KB=$((FM_CAPACITY_AVAILABLE_KB - FM_CAPACITY_RESERVE_KB))
  fm_local_firstmate_state_dirs "$state" || {
    FM_CAPACITY_ERROR=$FM_LOCAL_FIRSTMATE_ERROR; return 75;
  }
  for dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    if [ ! -d "$dir" ] || [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
      FM_CAPACITY_ERROR="machine state $dir is unreadable"; return 75
    fi
    for meta in "$dir"/*.meta; do
      [ -e "$meta" ] || [ -L "$meta" ] || continue
      [ "$meta" != "$state/$self.meta" ] || continue
      if [ ! -f "$meta" ] || [ -L "$meta" ] || [ ! -r "$meta" ]; then
        FM_CAPACITY_ERROR="task record $meta is unreadable or unsafe"; return 75
      fi
      # Read once; a concurrent handoff or cleanup can only free capacity.
      raw=$(cat -- "$meta") || { FM_CAPACITY_ERROR="cannot read task record $meta"; return 75; }
      kind=$(printf '%s\n' "$raw" | sed -n 's/^kind=//p' | head -1)
      if [ "$kind" = secondmate ]; then
        FM_CAPACITY_SECONDMATES=$((FM_CAPACITY_SECONDMATES + 1)); continue
      fi
      printf '%s\n' "$raw" | grep -q '^pr=.' && continue
      backend=$(printf '%s\n' "$raw" | sed -n 's/^backend=//p' | tail -1)
      target=$(printf '%s\n' "$raw" | sed -n 's/^window=//p' | tail -1)
      case "$(fm_backend_agent_state "${backend:-tmux}" "$target")" in
        dead|missing)
          worktree=$(printf '%s\n' "$raw" | sed -n 's/^worktree=//p' | tail -1)
          # Use teardown's bounded cwd scan, never a recursive file-tree walk.
          # Missing or unreadable worktree/process evidence retains the seat.
          if [[ "$worktree" = /* ]] && [ -d "$worktree" ] && [ -r "$worktree" ] && [ -x "$worktree" ] \
             && worktree=$(cd "$worktree" && pwd -P) \
             && processes=$(lsof -a -d cwd -Fpn 2>/dev/null); then
            holds=0 pid=
            while IFS= read -r line; do
              case "$line" in
                p*)
                  pid=${line#p}
                  case "$pid" in ''|*[!0-9]*) holds=1; break ;; esac
                  ;;
                fcwd) [ -n "$pid" ] || { holds=1; break; } ;;
                n*)
                  [ -n "$pid" ] || { holds=1; break; }
                  path=${line#n}
                  case "$path" in
                    "$worktree"|"$worktree"/*)
                      [ "$pid" != "$$" ] || continue
                      name=$(ps -p "$pid" -o comm= 2>/dev/null) || { holds=1; break; }
                      args=$(ps -p "$pid" -o args= 2>/dev/null) || { holds=1; break; }
                      [ -n "$name" ] && [ -n "$args" ] || { holds=1; break; }
                      read -r argv0 _ <<< "$args"
                      if [ "$(fm_agent_process_classify "$name" "$argv0" "$args" "$pid")" != shell ]; then
                        holds=1; break
                      fi
                      ;;
                  esac
                  ;;
                '') ;;
                *) holds=1; break ;;
              esac
            done <<< "$processes"
            [ "$holds" -ne 0 ] || continue
          fi
          ;;
      esac
      FM_CAPACITY_LANES=$((FM_CAPACITY_LANES + 1))
    done
  done
  FM_CAPACITY_FREE=$((FM_CAPACITY_TARGET - FM_CAPACITY_LANES))
  [ "$FM_CAPACITY_FREE" -ge 0 ] || FM_CAPACITY_FREE=0
  if [ "$FM_CAPACITY_HEADROOM_KB" -lt 0 ]; then
    FM_CAPACITY_FREE=0 FM_CAPACITY_REASON=memory
    FM_CAPACITY_ERROR="$meminfo MemAvailable=$FM_CAPACITY_AVAILABLE_KB kB minus reserve=$FM_CAPACITY_RESERVE_KB kB ($FM_CAPACITY_FILE) gives headroom=$FM_CAPACITY_HEADROOM_KB kB"
    return 75
  fi
  if [ "$FM_CAPACITY_FREE" -eq 0 ]; then
    FM_CAPACITY_REASON=full
    FM_CAPACITY_ERROR="$FM_CAPACITY_FILE: lanes=$FM_CAPACITY_LANES target=$FM_CAPACITY_TARGET; no free machine lane"
    return 75
  fi
  FM_CAPACITY_REASON=ok
}

fm_capacity_json() { # result of the latest fm_capacity_read, including refusals
  jq -cn --arg machine "$(hostname)" --arg reason "$FM_CAPACITY_REASON" \
    --arg error "$FM_CAPACITY_ERROR" --arg file "$FM_CAPACITY_FILE" \
    --argjson lanes "$FM_CAPACITY_LANES" --argjson target "$FM_CAPACITY_TARGET" \
    --argjson free "$FM_CAPACITY_FREE" --argjson secondmates "$FM_CAPACITY_SECONDMATES" \
    --argjson available "$FM_CAPACITY_AVAILABLE_KB" --argjson reserve "$FM_CAPACITY_RESERVE_KB" \
    --argjson headroom "$FM_CAPACITY_HEADROOM_KB" \
    '{schema:"fm-lane-capacity.v1",machine:$machine,generated_epoch:(now|floor),
      readable:($reason != "unreadable"),reason:$reason,error:$error,config_file:$file,
      lanes:$lanes,target:$target,free_lanes:$free,secondmates:$secondmates,
      mem_available_kb:$available,reserve_kb:$reserve,headroom_kb:$headroom}'
}
