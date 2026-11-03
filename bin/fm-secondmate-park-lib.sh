# shellcheck shell=bash disable=SC2034
# Durable owner park for one persistent secondmate. Source only.
#
# This is not the watcher crash-loop bound. That marker is
# state/.secondmate-relaunch-bound-<id>, read by fm_secondmate_parked in
# bin/fm-secondmate-liveness-lib.sh, and a successful launch or a later live
# probe clears it through fm_secondmate_liveness_rearm. An owner park stays
# until bin/fm-secondmate-park.sh unpark removes it. Rearm never reads it.
#
# Record, on the primary home that relaunches the mate:
#   $CONFIG/secondmate-parked/<id>
#   directory mode 0700, file mode 0600, exactly one line: owner YYYY-MM-DD
#   CONFIG is FM_CONFIG_OVERRIDE, otherwise $FM_HOME/config.
# The id is one path segment matching [A-Za-z0-9._-]. The date is a real UTC
# calendar day: GNU date must print that same day back (a rolled day such as
# 2026-02-31 is rejected), and BSD date is the fallback when GNU date is absent.
# A missing file means not parked. A symlink, a non-regular file, an unreadable
# file, extra lines, or a date this check rejects is unsafe: relaunch is refused
# and unpark will not remove a symlink.
#
# fm_secondmate_owner_parked <config-dir> <id> is side-effect free. It does not
# create the directory. It returns 0 and sets FM_SECONDMATE_OWNER_PARK_REASON
# and FM_SECONDMATE_OWNER_PARK_CLASS=parked|unsafe when relaunch must stop.
# It returns 1 and clears both when there is no record.
# bin/fm-secondmate-park.sh owns writes and removals, including the explicit
# remote mirror through bin/fm-remote-inherit.sh.

# <YYYY-MM-DD> -> the same day on stdout, or return 1 when it is not one.
fm_secondmate_owner_park_canonical_date() {
  local raw=$1 norm
  case "$raw" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  if norm=$(date -u -d "$raw" +%Y-%m-%d 2>/dev/null); then
    [ "$norm" = "$raw" ] || return 1
    printf '%s\n' "$norm"
    return 0
  fi
  if norm=$(date -u -j -f %Y-%m-%d "$raw" +%Y-%m-%d 2>/dev/null); then
    [ "$norm" = "$raw" ] || return 1
    printf '%s\n' "$norm"
    return 0
  fi
  return 1
}

# Prints the config directory the park record lives under, or returns 1 when
# neither FM_CONFIG_OVERRIDE nor FM_HOME is set. Does not create it.
fm_secondmate_owner_park_config() {
  if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_CONFIG_OVERRIDE"
    return 0
  fi
  if [ -n "${FM_HOME:-}" ]; then
    printf '%s\n' "$FM_HOME/config"
    return 0
  fi
  return 1
}

fm_secondmate_owner_park_refuse() { # <path> <reason-tail>
  FM_SECONDMATE_OWNER_PARK_CLASS=unsafe
  FM_SECONDMATE_OWNER_PARK_REASON="owner park record $1 $2"
}

# <config-dir> <id>
fm_secondmate_owner_parked() {
  local config=$1 id=$2 path line first='' n=0 date norm
  FM_SECONDMATE_OWNER_PARK_REASON=
  FM_SECONDMATE_OWNER_PARK_CLASS=
  case "$id" in
    ''|*[!A-Za-z0-9._-]*)
      FM_SECONDMATE_OWNER_PARK_CLASS=unsafe
      FM_SECONDMATE_OWNER_PARK_REASON="owner park id is unsafe; relaunch refused"
      return 0
      ;;
  esac
  if [ -z "$config" ]; then
    FM_SECONDMATE_OWNER_PARK_CLASS=unsafe
    FM_SECONDMATE_OWNER_PARK_REASON="owner park config directory is empty; relaunch refused"
    return 0
  fi
  path="$config/secondmate-parked/$id"
  if [ -L "$path" ]; then
    fm_secondmate_owner_park_refuse "$path" "is a symlink; relaunch refused (unpark will not remove a symlink)"
    return 0
  fi
  if [ ! -e "$path" ]; then
    return 1
  fi
  if [ ! -f "$path" ]; then
    fm_secondmate_owner_park_refuse "$path" "is not a regular file; relaunch refused"
    return 0
  fi
  if [ ! -r "$path" ]; then
    fm_secondmate_owner_park_refuse "$path" "is not readable; relaunch refused"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ "$n" -gt 1 ]; then
      break
    fi
    first=$line
  done < "$path"
  line=$first
  if [ "$n" -ne 1 ]; then
    fm_secondmate_owner_park_refuse "$path" "is not a single owner YYYY-MM-DD line; relaunch refused"
    return 0
  fi
  date=${line#owner }
  if [ "$line" = "$date" ] || [ "${line%% *}" != owner ]; then
    fm_secondmate_owner_park_refuse "$path" "is not a single owner YYYY-MM-DD line; relaunch refused"
    return 0
  fi
  if ! norm=$(fm_secondmate_owner_park_canonical_date "$date"); then
    fm_secondmate_owner_park_refuse "$path" "is not a single owner YYYY-MM-DD line; relaunch refused"
    return 0
  fi
  FM_SECONDMATE_OWNER_PARK_CLASS=parked
  FM_SECONDMATE_OWNER_PARK_REASON="owner park since $norm; relaunch refused until bin/fm-secondmate-park.sh unpark $id"
  return 0
}
