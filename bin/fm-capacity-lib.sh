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
# Numeric memory, pressure and disk facts come from fm-machine-resources.py.
# Physical occupied/free seats come from the installed
# $HOME/.config/skills-master/.agents/skills/activity/activity.sh --machine-json.
# The reader receives the machine root home and, for replacement admission,
# the replaced task's metadata path; unavailable or invalid lane facts refuse.
# Admission refusal never changes the physical free-seat count.
# Refusals report available_kb, pressure_full_avg60, floor_kb, reserve_kb and
# pressure_limit, using explicit unknowns for readings not yet available.
# Independent resource floors and pressure/disk admission are owned by
# fm-machine-resources.py and require config/machine-admission.json in that root.
# Every resource verdict is also appended, best effort, to
# <state>/machine-admission.log by fm_capacity_sample below; a failed write never
# changes the verdict.
# Unreadable config, state, registry or resource facts fail closed with exit 75.
# Admission is a fresh reading before launch, including relaunch. No machine
# lock is held across launch; reports and placement advice reserve no lane.

# One tab-separated line per resource verdict, so before/after admission can be
# tabulated against real free memory. Columns:
#   epoch verdict(yes|no|unknown) full_avg10 full_avg60 full_avg300
#   mem_available_kb effective_available_kb policy_sha256 reasons
# PSI columns are the maximum over the host and memory-controller ancestors.
# Unknown verdicts leave the reading columns empty. The log rotates to .1 once
# it exceeds FM_ADMISSION_LOG_MAX_BYTES (default 2 MiB), so at most two files exist.
fm_capacity_sample() { # <state> <reader-json> <reader-status>
  local log="$1/machine-admission.log" line max=${FM_ADMISSION_LOG_MAX_BYTES:-2097152} size
  line=$(jq -er --arg status "$3" '
    def n: if type == "number" then tostring else "" end;
    [(now|floor|tostring),
     (if .readable != true or ($status != "0" and $status != "75") then "unknown"
      elif .admitted == true then "yes" else "no" end),
     (.memory_full_avg10|n), (.memory_full_avg60|n), (.memory_full_avg300|n),
     (if .mem_available_bytes then (.mem_available_bytes/1024|floor|tostring) else "" end),
     (if .effective_available_bytes then (.effective_available_bytes/1024|floor|tostring) else "" end),
     (.resource_policy_sha256 // ""),
     ((.refusal_reasons // []) | join("; ") | gsub("[\t\n]"; " "))] | join("\t")
  ' <<< "$2" 2>/dev/null) || line="$(date +%s)	unknown							resource reader output unreadable"
  { printf '%s\n' "$line" >> "$log"; } 2>/dev/null || return 0
  size=$(wc -c < "$log" 2>/dev/null) || return 0
  if [ "$((size))" -gt "$max" ]; then mv -f -- "$log" "$log.1" 2>/dev/null || true; fi
  return 0
}

fm_capacity_read() { # <home> <config> <state> [replaced-task-id] [sample=1]
  local rc=0 measurements='available_kb=unknown pressure_full_avg60=unknown floor_kb=unknown reserve_kb=unknown pressure_limit=unknown'
  _fm_capacity_read "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    FM_CAPACITY_ERROR="$FM_CAPACITY_ERROR; $measurements"
  fi
  return "$rc"
}

_fm_capacity_read() {
  local home=$1 config=$2 state=$3 self=${4:-} config_dir raw ceiling reserve extra root_home dir meta kind pressure_limit
  local available memory_source
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
  FM_CAPACITY_TARGET=$((10#$ceiling))
  FM_CAPACITY_RESERVE_KB=$((10#$reserve * 1048576))
  measurements="available_kb=unknown pressure_full_avg60=unknown floor_kb=unknown reserve_kb=$FM_CAPACITY_RESERVE_KB pressure_limit=unknown"
  resources=$(python3 "${BASH_SOURCE[0]%/*}/fm-machine-resources.py" --policy "$config_dir/machine-admission.json") || resource_status=$?
  [ "${5:-1}" = 0 ] || fm_capacity_sample "$state" "$resources" "$resource_status"
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
  available=$FM_CAPACITY_EFFECTIVE_KB
  memory_source='fm-machine-resources.py clean-cache host/cgroup minimum'
  FM_CAPACITY_AVAILABLE_KB=$available
  FM_CAPACITY_HEADROOM_KB=$((FM_CAPACITY_AVAILABLE_KB - FM_CAPACITY_RESERVE_KB))
  pressure_limit=$(jq -r '.policy.memory_full_avg60_max' <<< "$resources")
  measurements="available_kb=$FM_CAPACITY_AVAILABLE_KB pressure_full_avg60=$FM_CAPACITY_PRESSURE floor_kb=$FM_CAPACITY_FLOOR_KB reserve_kb=$FM_CAPACITY_RESERVE_KB pressure_limit=$pressure_limit"
  local activity="$HOME/.config/skills-master/.agents/skills/activity/activity.sh" lane_facts
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then activity=${FM_ACTIVITY_READER:-$activity}; fi
  root_home=$(fm_firstmate_root_home "$home") || {
    FM_CAPACITY_ERROR="cannot resolve machine root for $home"; return 75;
  }
  lane_facts=$(FM_ROOT_OVERRIDE="${BASH_SOURCE[0]%/*}/.." FM_CONFIG_OVERRIDE="$config_dir" \
    bash "$activity" --machine-json "$root_home" "${self:+$state/$self.meta}") || {
    FM_CAPACITY_ERROR="activity live-process lane reader unavailable: $activity"; return 75;
  }
  if ! jq -e '.readable == true and
      ([.lanes, .target] | all(type == "number" and . >= 0 and . == floor))' \
      >/dev/null 2>&1 <<< "$lane_facts"; then
    FM_CAPACITY_ERROR='activity lane count is unreadable'; return 75
  fi
  FM_CAPACITY_LANES=$(jq -r .lanes <<< "$lane_facts")
  [ "$(jq -r .target <<< "$lane_facts")" = "$FM_CAPACITY_TARGET" ] || {
    FM_CAPACITY_ERROR='activity target changed during capacity read'; return 75;
  }
  fm_local_firstmate_state_dirs "$state" || {
    FM_CAPACITY_ERROR=$FM_LOCAL_FIRSTMATE_ERROR; return 75;
  }
  for dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || {
      FM_CAPACITY_ERROR="machine state $dir is unreadable"; return 75;
    }
    for meta in "$dir"/*.meta; do
      [ -e "$meta" ] || [ -L "$meta" ] || continue
      [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || {
        FM_CAPACITY_ERROR="task record $meta is unreadable or unsafe"; return 75;
      }
      raw=$(cat -- "$meta") || { FM_CAPACITY_ERROR="cannot read task record $meta"; return 75; }
      kind=$(sed -n 's/^kind=//p' <<< "$raw" | head -1)
      if [ "$kind" = secondmate ]; then FM_CAPACITY_SECONDMATES=$((FM_CAPACITY_SECONDMATES + 1)); fi
    done
  done
  FM_CAPACITY_FREE=$((FM_CAPACITY_TARGET - FM_CAPACITY_LANES))
  [ "$FM_CAPACITY_FREE" -ge 0 ] || FM_CAPACITY_FREE=0
  if [ "$FM_CAPACITY_HEADROOM_KB" -lt 0 ]; then
    FM_CAPACITY_REASON=memory
    FM_CAPACITY_ERROR="$memory_source=$FM_CAPACITY_AVAILABLE_KB kB minus reserve=$FM_CAPACITY_RESERVE_KB kB ($FM_CAPACITY_FILE) gives headroom=$FM_CAPACITY_HEADROOM_KB kB; $(jq -r '.refusal_reasons | join("; ")' <<< "$resources")"
    return 75
  fi
  if [ "$resource_status" -ne 0 ]; then
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
      admitted:($reason == "ok" and $free > 0),
      lanes:$lanes,target:$target,free_lanes:$free,secondmates:$secondmates,
      mem_available_kb:$available,reserve_kb:$reserve,headroom_kb:$headroom,
      resource_policy_sha256:$policy_sha256,memory_floor_kb:$floor,effective_available_kb:$effective,
      memory_full_avg60:$pressure,disk_free_min_kb:$disk}'
}
