#!/usr/bin/env bash
# Live driver: real `fm-lane-release.sh arm`, real check shim, real fm-watch.sh,
# against disposable lab homes. Usage: drive-shim-live.sh <repo-worktree> <commit-label> <commit>
set -u
REPO=$1 LABEL=$2 COMMIT=$3
BASE_PATH=$PATH
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-shim-live.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
run_env=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE)

export_code() { mkdir -p "$2"; git -C "$REPO" archive "$1" | tar -x -C "$2"; }

# one watcher pass: the watcher exits on the first wake; bound it at 60 s.
watch_once() {  # <home> <code-root-for-watcher>
  local home=$1 root=$2 rc=0
  "${run_env[@]}" FM_HOME="$home" FM_CHECK_INTERVAL=0 FM_POLL=0.05 FM_HEARTBEAT=999999 \
    FM_SIGNAL_GRACE=0 timeout 60 "$root/bin/fm-watch.sh" > "$home/watch.out" 2> "$home/watch.err" || rc=$?
  echo "  watcher exit=$rc"
  echo "  watcher stdout:"; sed 's/^/    | /' "$home/watch.out"
  [ -s "$home/watch.err" ] && { echo "  watcher stderr (tail):"; tail -5 "$home/watch.err" | sed 's/^/    | /'; }
  return 0
}

scenario() {  # <name> <home-has-own-bin: yes|no|noexec> <remove-arming-root: yes|no>
  local name=$1 own=$2 rmarm=$3 home arm
  echo "=== [$LABEL $COMMIT] scenario: $name (home bin=$own, arming root removed=$rmarm)"
  home="$WORK/$name-home"; arm="$WORK/$name-arming-checkout"
  "${run_env[@]}" "$REPO/bin/fm-lab-home.sh" create "$home" >/dev/null
  [ "$own" = no ] || export_code "$COMMIT" "$home"
  [ "$own" = noexec ] && chmod 0644 "$home/bin/fm-lane-release.sh"
  export_code "$COMMIT" "$arm"
  printf 'bogus-word\n' > "$home/config/lane-release"   # the real sweep reports this word
  "${run_env[@]}" FM_HOME="$home" "$arm/bin/fm-lane-release.sh" arm | sed 's/^/  arm: /'
  echo "  shim:"; sed 's/^/    | /' "$home/state/lane-release.check.sh"
  [ "$rmarm" = yes ] && { rm -rf -- "$arm"; echo "  removed arming checkout $arm"; }
  echo "  direct shim run (stderr+stdout):"
  ( "${run_env[@]}" bash "$home/state/lane-release.check.sh" 2>&1; echo "    rc=$?" ) | sed 's/^/    | /'
  rm -f -- "$home/state/.lane-release-invalid"
  # watcher code root: a surviving checkout (the gate repo itself) so only the shim's path matters
  watch_once "$home" "$REPO"
  echo "  home state/.lane-release-invalid: $(cat "$home/state/.lane-release-invalid" 2>/dev/null || echo '<absent>')"
  rm -rf -- "$home"
}

scenario home-root-survives-arming-removal yes yes
scenario fallback-to-arming-root no no
scenario nothing-executable-anywhere noexec yes
