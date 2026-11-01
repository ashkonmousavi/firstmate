#!/usr/bin/env bash
set -euo pipefail
SRC=$PWD
E=~/.no-mistakes/evidence/01M6BND9PKB3P0JYRZA36Y781C
W=$(mktemp -d "$SRC/.test-phase-tmp/race.XXXXXX")
pid=''
cleanup() {
  if [ -n "$pid" ]; then
    kill -CONT -- "-$pid" 2>/dev/null || true
    kill -TERM -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf "$W"
}
trap cleanup EXIT
mkdir -p "$W/user" "$W/tmp" "$W/config" "$W/gh"
export HOME="$W/user" TMPDIR="$W/tmp" GH_CONFIG_DIR="$W/gh" XDG_CONFIG_HOME="$W/config" GH_PROMPT_DISABLED=1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN TASKS_AXI_FILE TASKS_AXI_BACKEND FM_TASK_ID
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export TMUX="$W/private-tmux-socket,0,0" FM_BACKEND=tmux
export FM_ROOT_OVERRIDE="$SRC"
git init -q -b main "$W/project"
printf 'published content\n' > "$W/project/file"
git -C "$W/project" add file
git -C "$W/project" commit -qm published
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git -C "$W/project" remote add origin "$W/origin.git"
git -C "$W/project" push -q origin main
git clone -q "$W/origin.git" "$W/worker"
. "$SRC/bin/fm-pr-lib.sh"
. "$SRC/bin/fm-wake-lib.sh"
cp "$SRC/bin/fm-pr-poll.sh" "$W/old-poll.sh"
printf '# older authenticated poll\n' >> "$W/old-poll.sh"
fingerprint() {
  local suffix f
  for suffix in meta check.sh pr-poll pr-poll-registration; do
    f="$FM_STATE_OVERRIDE/task.$suffix"
    if [ -f "$f" ]; then
      printf '%s %s %s\n' "$suffix" "$(fm_pr_file_identity "$f")" "$(fm_pr_sha256 "$f")"
    fi
  done
}
for mode in retired replacement same-url; do
  export FM_HOME="$W/$mode" FM_STATE_OVERRIDE="$W/$mode/state" FM_CONFIG_OVERRIDE="$W/$mode/config"
  mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE" "$FM_HOME/data"
  printf 'kind=ship\nmode=direct-PR\nworktree=%s\nproject=%s\npr=https://github.com/octocat/Hello-World/pull/1\n' "$W/worker" "$W/worker" > "$FM_STATE_OVERRIDE/task.meta"
  fm_pr_poll_prepare "$FM_STATE_OVERRIDE" task github https://github.com/octocat/Hello-World/pull/1 github.com octocat/Hello-World 1 "$W/old-poll.sh"
  fm_pr_poll_publish_prepared
  meta_lock=$(fm_meta_lock_path "$FM_STATE_OVERRIDE/task.meta")
  fm_lock_acquire_wait "$meta_lock"
  # The real owner stages its replacement, then blocks at the held metadata lock.
  setsid bash "$SRC/bin/fm-pr-check-rearm.sh" > "$E/race-$mode.log" 2>&1 &
  pid=$!
  staged=0
  for ((i=0; i<300; i++)); do
    for candidate in "$FM_STATE_OVERRIDE"/.fm-pr-poll-data.*; do
      if [ -f "$candidate" ]; then staged=1; break; fi
    done
    [ "$staged" -eq 0 ] || break
    sleep 0.05
  done
  [ "$staged" -eq 1 ]
  # Freeze the whole refresh process group while a real competing owner wins.
  kill -STOP -- "-$pid"
  for ((i=0; i<100; i++)); do
    [[ "$(ps -o stat= -p "$pid")" != T* ]] || break
    sleep 0.02
  done
  [[ "$(ps -o stat= -p "$pid")" = T* ]]
  fm_lock_release "$meta_lock"
  if [ "$mode" = retired ]; then
    bash "$SRC/bin/fm-pr-poll-retire.sh" task --reason 'retired while update refresh was pending'
  else
    url=https://github.com/octocat/Hello-World/pull/2
    [ "$mode" != same-url ] || url=https://github.com/octocat/Hello-World/pull/1
    bash "$SRC/bin/fm-pr-check.sh" task "$url"
  fi
  fingerprint > "$E/race-$mode-before.tsv"
  kill -CONT -- "-$pid"
  set +e
  wait "$pid"
  rc=$?
  set -e
  pid=''
  [ "$rc" -eq 0 ]
  fingerprint > "$E/race-$mode-after.tsv"
  cmp "$E/race-$mode-before.tsv" "$E/race-$mode-after.tsv"
  cat "$E/race-$mode.log"
  grep -q 'skipped=superseded-or-retired' "$E/race-$mode.log"
  grep -q 'rearmed=0 left=0' "$E/race-$mode.log"
  printf 'Concurrent %s wins: metadata and artifact hashes plus identities preserved; refresh exit=%s\n' "$mode" "$rc"
done
