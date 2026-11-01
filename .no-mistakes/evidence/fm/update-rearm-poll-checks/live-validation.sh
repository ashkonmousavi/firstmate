#!/usr/bin/env bash
# Run from the gate worktree; all fixtures remain inside it. No fleet data or credentials.
set -euo pipefail
SRC=$PWD
E=~/.no-mistakes/evidence/01M6BND9PKB3P0JYRZA36Y781C
W=$(mktemp -d "$SRC/.test-phase-tmp/live.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/user" "$W/tmp" "$W/gh" "$W/xdg"
export HOME="$W/user" TMPDIR="$W/tmp" GH_CONFIG_DIR="$W/gh" XDG_CONFIG_HOME="$W/xdg" XDG_CACHE_HOME="$W/user/cache" XDG_DATA_HOME="$W/user/data"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
export GH_PROMPT_DISABLED=1
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN TASKS_AXI_FILE TASKS_AXI_BACKEND FM_TASK_ID
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
# Point even read-only endpoint discovery at a nonexistent private socket; never the default server.
export TMUX="$W/private-tmux-socket,0,0" FM_BACKEND=tmux
export FM_HOME="$W/primary-home"
mkdir -p "$W/seed"
git archive HEAD | tar -x -C "$W/seed"
printf '\n# Earlier authenticated generation; never execute these stored bytes.\nprintf unsafe > "$FM_HOME/OLD-PROGRAM-EXECUTED"\n' >> "$W/seed/bin/fm-pr-poll.sh"
git init -q -b main "$W/seed"
git -C "$W/seed" add -A
git -C "$W/seed" commit -qm earlier-generation
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git -C "$W/seed" remote add origin "$W/origin.git"
git -C "$W/seed" push -q origin main
git clone -q "$W/origin.git" "$W/main"
git -C "$W/main" worktree add -q --detach "$W/local-home" main
git clone -q "$W/origin.git" "$W/remote-root"
git clone -q "$W/origin.git" "$W/remote-home"
git -C "$W/remote-home" checkout -q --detach
# A real published local task and a task whose latest commit was never pushed.
git init -q -b main "$W/project"
printf 'published work\n' > "$W/project/file"
git -C "$W/project" add file
git -C "$W/project" commit -qm published
git init -q --bare "$W/project-origin.git"
git -C "$W/project-origin.git" symbolic-ref HEAD refs/heads/main
git -C "$W/project" remote add origin "$W/project-origin.git"
git -C "$W/project" push -q origin main
git clone -q "$W/project-origin.git" "$W/worker"
git clone -q "$W/project-origin.git" "$W/unpublished"
printf 'unpublished work\n' >> "$W/unpublished/file"
git -C "$W/unpublished" commit -qam unpublished
. "$SRC/bin/fm-pr-lib.sh"
for home in "$W/primary-home" "$W/local-home" "$W/remote-root" "$W/remote-home"; do
  mkdir -p "$home/state" "$home/config" "$home/data"
  touch "$home/state/.last-watcher-beat"
  for id in ready missing unreachable tampered; do
    wt="$W/worker"
    [ "$id" != missing ] || wt="$W/deleted-copy"
    [ "$id" != unreachable ] || wt="$W/unpublished"
    printf 'kind=ship\nmode=direct-PR\nworktree=%s\nproject=%s\npr=https://github.com/octocat/Hello-World/pull/1\n' "$wt" "$wt" > "$home/state/$id.meta"
    fm_pr_poll_prepare "$home/state" "$id" github https://github.com/octocat/Hello-World/pull/1 github.com octocat/Hello-World 1 "$W/main/bin/fm-pr-poll.sh"
    fm_pr_poll_publish_prepared
  done
  printf '# tampered after registration\n' >> "$home/state/tampered.check.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/state/custom.check.sh"
  chmod 700 "$home/state/custom.check.sh"
  FM_HOME="$home" bash "$SRC/bin/fm-check-register.sh" custom
  sha256sum "$home/state/custom.check.sh" "$home/state/custom.check-trust" > "$home/state/custom-before.sha"
done
printf 'local\n' > "$W/local-home/.fm-secondmate-home"
printf 'remote\n' > "$W/remote-home/.fm-secondmate-home"
printf -- '- local - offline mate (home: %s/local-home; scope: lab; projects: none; added 2026-11-01)\n' "$W" > "$W/primary-home/data/secondmates.md"
# Change only the installed poll program to model the fleet-update regression.
cp "$SRC/bin/fm-pr-poll.sh" "$W/seed/bin/fm-pr-poll.sh"
git -C "$W/seed" add bin/fm-pr-poll.sh
git -C "$W/seed" commit -qm current-generation
git -C "$W/seed" push -q origin main
TARGET=$(git -C "$W/seed" rev-parse HEAD)
# Use the real watcher on a dedicated state-only lab before repair. It must reject the old ready poll.
mkdir -p "$W/watch-before"
for suffix in meta check.sh pr-poll pr-poll-registration; do
  mv "$W/primary-home/state/ready.$suffix" "$W/watch-before/ready.$suffix"
done
# Moving to another directory preserves the registered file identities.
set +e
FM_HOME="$W/primary-home" FM_ROOT_OVERRIDE="$SRC" FM_STATE_OVERRIDE="$W/watch-before" FM_CONFIG_OVERRIDE="$W/primary-home/config" \
 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 timeout 20 bash "$SRC/bin/fm-watch.sh" > "$E/watcher-before.log" 2>&1
rc=$?
set -e
printf 'watcher-before exit=%s\n' "$rc"
grep -q 'rejected unauthenticated state checks:.*ready.check.sh' "$E/watcher-before.log"
cat "$E/watcher-before.log"
for suffix in meta check.sh pr-poll pr-poll-registration; do
  mv "$W/watch-before/ready.$suffix" "$W/primary-home/state/ready.$suffix"
done
for code_home in main local-home remote-root remote-home; do
  status=$(git -C "$W/$code_home" status --porcelain)
  printf 'Fixture checkout %s status=%s\n' "$code_home" "${status:-clean}"
  [ -z "$status" ]
done
printf '\n=== Primary and registry-only home update ===\n'
FM_HOME="$W/primary-home" FM_ROOT_OVERRIDE="$W/main" FM_STATE_OVERRIDE="$W/primary-home/state" FM_CONFIG_OVERRIDE="$W/primary-home/config" \
 bash "$SRC/bin/fm-update.sh" | tee "$E/update-first.log"
for home in "$W/primary-home" "$W/local-home"; do
  grep -Fq "home=$home rearmed=1 left=3" "$E/update-first.log"
  cmp "$home/state/ready.check.sh" "$SRC/bin/fm-pr-poll.sh"
  fm_pr_poll_artifacts_valid "$home/state" ready "$SRC/bin/fm-pr-poll.sh"
  sha256sum -c "$home/state/custom-before.sha"
done
ready_identity=$(fm_pr_file_identity "$W/primary-home/state/ready.check.sh")
printf '\n=== Already-current retry ===\n'
FM_HOME="$W/primary-home" FM_ROOT_OVERRIDE="$W/main" FM_STATE_OVERRIDE="$W/primary-home/state" FM_CONFIG_OVERRIDE="$W/primary-home/config" \
 bash "$SRC/bin/fm-update.sh" | tee "$E/update-repeat.log"
[ "$ready_identity" = "$(fm_pr_file_identity "$W/primary-home/state/ready.check.sh")" ]
printf 'Valid primary poll identity preserved: %s\n' "$ready_identity"
grep -Fq "home=$W/primary-home rearmed=0 left=3" "$E/update-repeat.log"
printf '\n=== Host-local remote update (no remote endpoint or lifecycle) ===\n'
FM_HOME="$W/remote-home" FM_ROOT_OVERRIDE="$W/remote-root" FM_STATE_OVERRIDE="$W/primary-home/state" FM_CONFIG_OVERRIDE="$W/primary-home/config" \
 bash "$SRC/bin/fm-remote-secondmate-control.sh" update remote main "$TARGET" | tee "$E/update-remote.log"
for home in "$W/remote-root" "$W/remote-home"; do
  grep -Fq "home=$home rearmed=1 left=3" "$E/update-remote.log"
  fm_pr_poll_artifacts_valid "$home/state" ready "$SRC/bin/fm-pr-poll.sh"
  sha256sum -c "$home/state/custom-before.sha"
done
# The normal owner must preserve the stale failures and name the actual missing-copy/unreachable causes.
grep -q 'task=missing could-not-rearm reason=.*error: named head cannot be verified: worktree missing' "$E/update-first.log"
grep -q 'task=unreachable could-not-rearm reason=.*error: named head .* is unreachable outside the worker copy' "$E/update-first.log"
grep -q 'task=tampered could-not-rearm reason=unauthenticated-poll-generation' "$E/update-first.log"
# Prove the repaired watcher accepts registration. The isolated gh CLI has no login;
# reaching its explicit PR-query failure demonstrates authentication succeeded, not a merge event.
mkdir -p "$W/watch-after"
for suffix in meta check.sh pr-poll pr-poll-registration; do mv "$W/primary-home/state/ready.$suffix" "$W/watch-after/ready.$suffix"; done
set +e
FM_HOME="$W/primary-home" FM_ROOT_OVERRIDE="$SRC" FM_STATE_OVERRIDE="$W/watch-after" FM_CONFIG_OVERRIDE="$W/primary-home/config" \
 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 timeout 20 bash "$SRC/bin/fm-watch.sh" > "$E/watcher-after.log" 2>&1
rc=$?
set -e
printf 'watcher-after exit=%s\n' "$rc"
cat "$E/watcher-after.log"
! grep -q 'rejected unauthenticated state checks' "$E/watcher-after.log"
grep -q 'watcher: PR poll for ready failed (exit status' "$E/watcher-after.log"
for suffix in meta check.sh pr-poll pr-poll-registration; do mv "$W/watch-after/ready.$suffix" "$W/primary-home/state/ready.$suffix"; done
printf '\n=== Poll-only retirement and refusal boundaries ===\n'
home="$W/primary-home"
sha256sum "$home/state/missing.meta" "$W/unpublished/file" > "$home/state/work-before.sha"
FM_HOME="$home" bash "$SRC/bin/fm-pr-poll-retire.sh" missing --reason 'disposable copy no longer exists'
for suffix in check.sh pr-poll pr-poll-registration; do [ ! -e "$home/state/missing.$suffix" ]; done
sha256sum -c "$home/state/work-before.sha"
FM_HOME="$home" bash "$SRC/bin/fm-pr-poll-retire.sh" missing --reason 'repeat is harmless'
for id in tampered custom; do
  set +e
  FM_HOME="$home" bash "$SRC/bin/fm-pr-poll-retire.sh" "$id" --reason 'unsafe must refuse'
  rc=$?
  set -e
  [ "$rc" -ne 0 ]
  [ -f "$home/state/$id.check.sh" ]
  printf 'Refused %s with exit=%s; check preserved\n' "$id" "$rc"
done
printf 'pending-receipt\n' > "$home/state/unreachable.pr-poll-retirement"
set +e
FM_HOME="$home" bash "$SRC/bin/fm-pr-poll-retire.sh" unreachable --reason 'pending receipt must refuse'
rc=$?
set -e
[ "$rc" -ne 0 ] && [ -f "$home/state/unreachable.check.sh" ]
printf 'Pending merged receipt refused with exit=%s; check preserved\n' "$rc"
sha256sum -c "$home/state/custom-before.sha"
[ ! -e "$home/OLD-PROGRAM-EXECUTED" ]
printf '\nAll disposable CLI scenarios completed; stored old programs never executed.\n'
