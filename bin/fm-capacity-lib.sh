#!/usr/bin/env bash
# Shared machine lane facts and admission. No side effects on source.
# Requires fm-wake-lib.sh, fm-backend.sh, fm-secondmate-registry-lib.sh and
# fm-project-capacity-lib.sh. fm-capacity.sh is the public report/publish API.
#
# config/lane-capacity in the local root home is mandatory: one line with
# <lane-ceiling> <memory-reserve-gb>, both non-negative integers (up to 6 digits).
# GB here means 1024^3 bytes. Zero ceiling stops admission; the reserve check
# requires available memory minus reserve >= 0. There are no
# per-lane estimates and CPU load never refuses admission.
# Every local registered home is counted through fm_local_firstmate_state_dirs.
# Task records hold a lane under fm_task_record_holds_seat, the shared seat
# rule owned by bin/fm-project-capacity-lib.sh.
# A ready-PR handoff alone does not exempt a record from the lane count.
# Persistent secondmate records are exempt.
# External bots have no local records;
# ordinary local workers carrying walk markers still hold a lane.
# Available memory is the smallest memory.high minus (anon + shmem) balance
# across the current cgroup-v2 group and its ancestors with finite memory.high,
# using each group's own memory.stat and excluding reclaimable file cache.
# Only without a finite high limit, use /proc/meminfo's MemAvailable.
# Reports retain mem_available_kb for this pre-reserve balance, floored to KiB;
# headroom_kb subtracts the configured reserve. Either balance may be negative.
# Independent resource floors and pressure/disk admission are owned by
# fm-machine-resources.py and require config/machine-admission.json in that root.
# Unreadable config, state, registry or resource facts fail closed with exit 75.
# Admission is a fresh reading before launch, including relaunch. No machine
# lock is held across launch; reports and placement advice reserve no lane.

# shellcheck source=bin/fm-agent-process-lib.sh
. "${BASH_SOURCE[0]%/*}/fm-agent-process-lib.sh"

fm_capacity_read() { # <home> <config> <state> [replaced-task-id]
  local home=$1 config=$2 state=$3 self=${4:-} config_dir raw ceiling reserve extra
  local dir meta kind available meminfo=/proc/meminfo memory_source
  local cgroup_file=/proc/self/cgroup cgroup_root=/sys/fs/cgroup cgroup_path cgroup_dir high stats anon shmem bytes balance_kb
  FM_CAPACITY_ERROR='' FM_CAPACITY_REASON=unreadable
  FM_CAPACITY_LANES=0 FM_CAPACITY_SECONDMATES=0 FM_CAPACITY_FREE=0
  FM_CAPACITY_TARGET=0 FM_CAPACITY_RESERVE_KB=0 FM_CAPACITY_AVAILABLE_KB=0 FM_CAPACITY_HEADROOM_KB=0
  FM_CAPACITY_POLICY_SHA256='' FM_CAPACITY_FLOOR_KB=0 FM_CAPACITY_PRESSURE=0 FM_CAPACITY_DISK_KB=0 FM_CAPACITY_EFFECTIVE_KB=0
  local resources resource_status=0
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
  resources=$(python3 "${BASH_SOURCE[0]%/*}/fm-machine-resources.py" --policy "$config_dir/machine-admission.json") || resource_status=$?
  if [ "$resource_status" -ne 0 ] && [ "$resource_status" -ne 75 ]; then
    FM_CAPACITY_ERROR="resource reader failed for $config_dir/machine-admission.json"; return 75
  fi
  if ! jq -e '.readable == true' >/dev/null 2>&1 <<< "$resources"; then
    FM_CAPACITY_ERROR="$config_dir/machine-admission.json: $(jq -r '.refusal_reasons | join("; ")' <<< "$resources" 2>/dev/null)"; return 75
  fi
  FM_CAPACITY_POLICY_SHA256=$(jq -r '.resource_policy_sha256' <<< "$resources")
  FM_CAPACITY_FLOOR_KB=$(jq -r '.memory_floor_gib * 1048576 | floor' <<< "$resources")
  FM_CAPACITY_EFFECTIVE_KB=$(jq -r '.effective_available_bytes / 1024 | floor' <<< "$resources")
  FM_CAPACITY_PRESSURE=$(jq -r '.memory_full_avg60' <<< "$resources")
  FM_CAPACITY_DISK_KB=$(jq -r '[.disk_available_bytes[]] | min / 1024 | floor' <<< "$resources")
  FM_CAPACITY_TARGET=$((10#$ceiling))
  FM_CAPACITY_RESERVE_KB=$((10#$reserve * 1048576))
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then
    meminfo=${FM_CAPACITY_MEMINFO:-/proc/meminfo}
    # Host cgroups must not influence portable tests using fixture memory.
    cgroup_file=${FM_CAPACITY_CGROUP_FILE:-/dev/null}
    cgroup_root=${FM_CAPACITY_CGROUP_ROOT:-/sys/fs/cgroup}
  fi
  available='' memory_source="$meminfo MemAvailable"
  if [ -d "$cgroup_root" ]; then
    cgroup_path=$(awk -F: '
      $1 == "0" && $2 == "" { n++; path=$3; if (NF != 3) bad=1 }
      END { if (n > 1 || bad) exit 1; print path }
    ' "$cgroup_file" 2>/dev/null) || {
      FM_CAPACITY_ERROR="$cgroup_file: cgroup membership malformed or unreadable"; return 75;
    }
    if [ -n "$cgroup_path" ]; then
      case "${cgroup_path%/}/" in
        *'/../'*|*'/./'*|*'//'*)
          FM_CAPACITY_ERROR="$cgroup_file: invalid cgroup path"; return 75 ;;
      esac
      [[ "$cgroup_path" = /* ]] || {
        FM_CAPACITY_ERROR="$cgroup_file: cgroup path is not absolute"; return 75;
      }
      cgroup_dir="${cgroup_root%/}${cgroup_path%/}"
      while :; do
        if [ ! -d "$cgroup_dir" ] || [ ! -r "$cgroup_dir" ] || [ ! -x "$cgroup_dir" ]; then
          FM_CAPACITY_ERROR="$cgroup_dir: cgroup directory unreadable"; return 75
        fi
        # memory.high is absent at the hierarchy root or with no controller.
        if [ -e "$cgroup_dir/memory.high" ] || [ -L "$cgroup_dir/memory.high" ]; then
          high=$(cat -- "$cgroup_dir/memory.high" 2>/dev/null) || {
            FM_CAPACITY_ERROR="$cgroup_dir/memory.high: unreadable"; return 75;
          }
          if [ "$high" != max ]; then
            [[ "$high" =~ ^[0-9]{1,15}$ ]] || {
              FM_CAPACITY_ERROR="$cgroup_dir/memory.high: malformed limit"; return 75;
            }
            # Kernel memory.stat is byte-valued and keyed, not position-based:
            # https://docs.kernel.org/admin-guide/cgroup-v2.html#memory-interface-files
            stats=$(awk '
              $1 == "anon" || $1 == "shmem" {
                count[$1]++
                if (NF != 2 || $2 !~ /^[0-9]+$/ || length($2) > 15) bad=1
                value[$1]=$2
              }
              END {
                if (bad || count["anon"] != 1 || count["shmem"] != 1) exit 1
                printf "%s %s\n", value["anon"], value["shmem"]
              }
            ' "$cgroup_dir/memory.stat" 2>/dev/null) || {
              FM_CAPACITY_ERROR="$cgroup_dir/memory.stat: anon or shmem missing, malformed or unreadable"; return 75;
            }
            read -r anon shmem <<< "$stats"
            bytes=$((10#$high - 10#$anon - 10#$shmem))
            # Floor to KiB, including a negative sub-KiB balance.
            if [ "$bytes" -lt 0 ]; then balance_kb=$(((bytes - 1023) / 1024))
            else balance_kb=$((bytes / 1024)); fi
            if [ -z "$available" ] || [ "$balance_kb" -lt "$available" ]; then
              available=$balance_kb
              memory_source="$cgroup_dir memory.high-(anon+shmem)"
            fi
          fi
        fi
        [ "$cgroup_dir" != "${cgroup_root%/}" ] || break
        cgroup_dir=${cgroup_dir%/*}
      done
    fi
  fi
  if [ -z "$available" ]; then
    available=$(awk '
      /^MemAvailable:/ { n++; if (NF == 3 && $2 ~ /^[0-9]+$/ && length($2) <= 13 && $3 == "kB") value=$2; else bad=1 }
      END { if (n != 1 || bad) exit 1; print value }
    ' "$meminfo" 2>/dev/null) || {
      FM_CAPACITY_ERROR="$meminfo: MemAvailable reading missing, malformed or unreadable"; return 75;
    }
    available=$((10#$available))
  fi
  FM_CAPACITY_AVAILABLE_KB=$available
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
      fm_task_record_holds_seat "$meta" "$raw" "$dir" || continue
      FM_CAPACITY_LANES=$((FM_CAPACITY_LANES + 1))
    done
  done
  FM_CAPACITY_FREE=$((FM_CAPACITY_TARGET - FM_CAPACITY_LANES))
  [ "$FM_CAPACITY_FREE" -ge 0 ] || FM_CAPACITY_FREE=0
  if [ "$FM_CAPACITY_HEADROOM_KB" -lt 0 ]; then
    FM_CAPACITY_FREE=0 FM_CAPACITY_REASON=memory
    FM_CAPACITY_ERROR="$memory_source=$FM_CAPACITY_AVAILABLE_KB kB minus reserve=$FM_CAPACITY_RESERVE_KB kB ($FM_CAPACITY_FILE) gives headroom=$FM_CAPACITY_HEADROOM_KB kB"
    return 75
  fi
  if [ "$resource_status" -ne 0 ]; then
    FM_CAPACITY_FREE=0
    FM_CAPACITY_ERROR=$(jq -r '.refusal_reasons | join("; ")' <<< "$resources")
    case "$FM_CAPACITY_ERROR" in
      *'memory floor'*) FM_CAPACITY_REASON=memory ;;
      *'PSI'*) FM_CAPACITY_REASON=pressure ;;
      *) FM_CAPACITY_REASON=disk ;;
    esac
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
    --arg policy_sha256 "$FM_CAPACITY_POLICY_SHA256" --argjson floor "$FM_CAPACITY_FLOOR_KB" \
    --argjson effective "$FM_CAPACITY_EFFECTIVE_KB" --argjson pressure "$FM_CAPACITY_PRESSURE" --argjson disk "$FM_CAPACITY_DISK_KB" \
    '{schema:"fm-lane-capacity.v1",machine:$machine,generated_epoch:(now|floor),
      readable:($reason != "unreadable"),reason:$reason,error:$error,config_file:$file,
      lanes:$lanes,target:$target,free_lanes:$free,secondmates:$secondmates,
      mem_available_kb:$available,reserve_kb:$reserve,headroom_kb:$headroom,
      resource_policy_sha256:$policy_sha256,memory_floor_kb:$floor,effective_available_kb:$effective,
      memory_full_avg60:$pressure,disk_free_min_kb:$disk}'
}
