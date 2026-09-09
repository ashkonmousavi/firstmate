#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
#
# Before recording pr=, the PR's head branch (read live from the forge) must
# be this task's own branch: fm_pr_branch_matches_task (bin/fm-pr-lib.sh)
# accepts either the branch actually checked out in the recorded worktree, or
# the fm/<task-id> stem allowing an optional -fixN or -rN retry suffix. This
# stops a PR built for other work (e.g. a foundation prerequisite) from being
# recorded as this task's own delivery, which teardown and the merge path then
# treat as landed once it merges (2026-09-05 shell/174 incident: PR 174 was
# recorded as this task's pr=, teardown found it merged, and the real shell PR
# was closed as a duplicate). Pass --prerequisite to record such a PR anyway,
# under prerequisite_pr= instead of pr= (no pr_head-equivalent, since no
# reader ever treats that key as this task's own delivery). The branch read
# needs gh for GitHub or jq for GitLab; when the needed tool is absent the check is
# skipped rather than refused, matching the pr_head lookup's own best-effort
# posture toward a missing gh.
#
# --absorbed-by binds an already-PR-ready constituent task to the combined PR
# that will actually land it. It requires the existing canonical pr= to be a
# different pull request in the same project, reads that original PR live, and
# requires it to be CLOSED rather than MERGED. Its exact live branch and head
# must still match the task worktree, and the combined PR's live head must
# contain that constituent head. The rewrite preserves these fields before the
# canonical pr= tail, whose ordinary poll then reports the combined landing for
# this task:
#   batch_role=constituent
#   batch_constituent_branch=<exact original PR branch>
#   batch_constituent_head=<exact original PR head sha>
#   batch_superseded_pr=<canonical original PR url>
#   batch_superseded_disposition=closed-as-superseded-not-merged
# Containment is verified against the combined PR's own head and nothing else:
# the constituent head is never required to reach the default branch, because a
# project may land every commit there as a squash merge, in which case no commit
# of any pull request is ever an ancestor of it. bin/fm-teardown.sh proves the
# same containment at cleanup from the combined PR's permanent refs/pull/<n>/head.
# A normal later registration refuses to overwrite this evidence; an exact
# --absorbed-by retry refreshes it idempotently. The metadata parser in
# bin/fm-pr-lib.sh needs no broader lifecycle-key allowance because the batch
# fields are written before pr=; the existing fixed post-pr tail stays closed.
#
# Usage: fm-pr-check.sh [--prerequisite|--absorbed-by] <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

PREREQUISITE=0
ABSORBED_BY=0
case "${1-}" in
  --prerequisite) PREREQUISITE=1; shift ;;
  --absorbed-by) ABSORBED_BY=1; shift ;;
esac
if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
if [ "$ABSORBED_BY" -eq 0 ] && [ "$PREREQUISITE" -eq 0 ] \
  && grep -q '^batch_role=constituent$' "$META" 2>/dev/null; then
  echo "error: task $ID already carries an absorbed-constituent binding; use --absorbed-by to refresh the same combined PR" >&2
  exit 1
fi
TASK_BRANCH=
TASK_HEAD=
if [ -n "$WT" ] && [ -d "$WT" ]; then
  TASK_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  TASK_HEAD=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null || true)
fi

ORIGINAL_URL=
ORIGINAL_PROVIDER=
ORIGINAL_HOST=
ORIGINAL_PATH=
ORIGINAL_NUMBER=
ORIGINAL_STATE=
ORIGINAL_BRANCH=
ORIGINAL_HEAD=
ORIGINAL_META_HASH=
RECORDED_URL=
RECORDED_BATCH_BRANCH=
RECORDED_BATCH_HEAD=
if [ "$ABSORBED_BY" -eq 1 ]; then
  [ -n "$TASK_BRANCH" ] && fm_pr_head_valid "$TASK_HEAD" \
    || { echo "error: absorbed constituent task $ID needs an inspectable branch and head" >&2; exit 1; }
  fm_pr_metadata_identity_parse "$META" \
    || { echo "error: absorbed constituent task $ID has no valid original pr= record" >&2; exit 1; }
  RECORDED_URL=$FM_PR_META_URL
  if [ "$RECORDED_URL" = "$URL" ]; then
    [ "$(grep '^batch_role=' "$META" | tail -1 | cut -d= -f2- || true)" = constituent ] \
      && [ "$(grep '^batch_superseded_disposition=' "$META" | tail -1 | cut -d= -f2- || true)" = closed-as-superseded-not-merged ] \
      || { echo "error: combined PR is already canonical without a valid constituent binding" >&2; exit 1; }
    ORIGINAL_URL=$(grep '^batch_superseded_pr=' "$META" | tail -1 | cut -d= -f2- || true)
    RECORDED_BATCH_BRANCH=$(grep '^batch_constituent_branch=' "$META" | tail -1 | cut -d= -f2- || true)
    RECORDED_BATCH_HEAD=$(grep '^batch_constituent_head=' "$META" | tail -1 | cut -d= -f2- || true)
  else
    ORIGINAL_URL=$RECORDED_URL
  fi
  fm_pr_url_parse "$ORIGINAL_URL" \
    || { echo "error: absorbed constituent task $ID has an invalid original PR record" >&2; exit 1; }
  ORIGINAL_PROVIDER=$FM_PR_PROVIDER
  ORIGINAL_HOST=$FM_PR_HOST
  ORIGINAL_PATH=$FM_PR_PATH
  ORIGINAL_NUMBER=$FM_PR_NUMBER
  ORIGINAL_META_HASH=$(fm_pr_sha256 "$META") || exit 1
  [ "$ORIGINAL_URL" != "$URL" ] \
    || { echo "error: absorbed constituent task $ID must name a different combined PR" >&2; exit 1; }
  [ "$ORIGINAL_PROVIDER" = "$PROVIDER" ] && [ "$ORIGINAL_HOST" = "$HOST" ] \
    && [ "$ORIGINAL_PATH" = "$PROJECT_PATH" ] \
    || { echo "error: absorbed constituent and combined PR must belong to the same project" >&2; exit 1; }
  case "$ORIGINAL_PROVIDER" in
    github)
      command -v gh >/dev/null 2>&1 \
        || { echo "error: --absorbed-by requires gh to verify the original pull request" >&2; exit 1; }
      ORIGINAL_STATE=$(cd "$WT" && gh pr view "$ORIGINAL_URL" --json state -q .state 2>/dev/null) || ORIGINAL_STATE=
      ORIGINAL_BRANCH=$(cd "$WT" && gh pr view "$ORIGINAL_URL" --json headRefName -q .headRefName 2>/dev/null) || ORIGINAL_BRANCH=
      ORIGINAL_HEAD=$(cd "$WT" && gh pr view "$ORIGINAL_URL" --json headRefOid -q .headRefOid 2>/dev/null) || ORIGINAL_HEAD=
      ;;
    gitlab)
      command -v glab >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
        || { echo "error: --absorbed-by requires glab and jq to verify the original merge request" >&2; exit 1; }
      ORIGINAL_JSON=$(GITLAB_HOST="$ORIGINAL_HOST" glab mr view "$ORIGINAL_NUMBER" \
        -R "https://$ORIGINAL_HOST/$ORIGINAL_PATH" -F json 2>/dev/null) || ORIGINAL_JSON=
      [ -n "$ORIGINAL_JSON" ] || { echo "error: could not read original PR $ORIGINAL_URL" >&2; exit 1; }
      ORIGINAL_STATE=$(printf '%s' "$ORIGINAL_JSON" | jq -r '.state // empty' 2>/dev/null) || ORIGINAL_STATE=
      ORIGINAL_BRANCH=$(printf '%s' "$ORIGINAL_JSON" | jq -r '.source_branch // empty' 2>/dev/null) || ORIGINAL_BRANCH=
      ORIGINAL_HEAD=$(printf '%s' "$ORIGINAL_JSON" | jq -r '.sha // empty' 2>/dev/null) || ORIGINAL_HEAD=
      ;;
  esac
  case "$ORIGINAL_STATE" in
    CLOSED|closed) ;;
    MERGED|merged)
      echo "error: original PR $ORIGINAL_URL is merged, not superseded" >&2
      exit 1
      ;;
    *)
      echo "error: original PR $ORIGINAL_URL must be closed as superseded before binding" >&2
      exit 1
      ;;
  esac
  fm_pr_branch_matches_task "$ORIGINAL_BRANCH" "$ID" "$TASK_BRANCH" \
    || { echo "error: original PR $ORIGINAL_URL no longer names task $ID's branch" >&2; exit 1; }
  fm_pr_head_valid "$ORIGINAL_HEAD" && [ "$ORIGINAL_HEAD" = "$TASK_HEAD" ] \
    || { echo "error: original PR $ORIGINAL_URL head does not match task $ID's exact current head" >&2; exit 1; }
  [ -z "$RECORDED_BATCH_BRANCH" ] \
    || { [ "$RECORDED_BATCH_BRANCH" = "$ORIGINAL_BRANCH" ] && [ "$RECORDED_BATCH_HEAD" = "$ORIGINAL_HEAD" ]; } \
    || { echo "error: existing constituent binding disagrees with the original PR's live branch or head" >&2; exit 1; }
fi

if [ "$PREREQUISITE" -eq 1 ]; then
  # A prerequisite record is informational only: no branch-identity check, no
  # merge poll, and no ready line, because this PR is never claimed to be this
  # task's own delivery. No pr_head-equivalent is captured here: nothing reads
  # it, since the whole point of prerequisite_pr= is that no landed test
  # consults it. prerequisite_pr= is written strictly before any existing
  # pr= tail because fm_pr_metadata_identity_parse rejects a record whose pr=
  # block is followed by anything outside its fixed lifecycle key set, and
  # prerequisite_pr= is deliberately not in that set: nothing appends it after
  # the block, so keeping it out keeps the guard as tight as it can be for a
  # task that has already recorded its own real PR.
  META_TMP=
  META_LOCK=
  META_LOCK_HELD=0
  # shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap below.
  prereq_cleanup() {
    [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
    if [ "$META_LOCK_HELD" = 1 ]; then
      fm_lock_release "$META_LOCK" || true
      META_LOCK_HELD=0
    fi
  }
  trap prereq_cleanup EXIT
  trap 'exit 1' HUP INT TERM

  META_LOCK=$(fm_meta_lock_path "$META") || exit 1
  fm_lock_acquire_wait "$META_LOCK"
  META_LOCK_HELD=1
  [ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
    || { echo "error: task metadata is unavailable" >&2; exit 1; }
  META_DEVICE=$(fm_pr_file_device "$META") || exit 1
  STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
  [ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
  META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
  HEAD_LINES=()
  TAIL_LINES=()
  IN_TAIL=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$IN_TAIL" -eq 1 ]; then
      TAIL_LINES+=("$line")
      continue
    fi
    case "$line" in
      pr=*) IN_TAIL=1; TAIL_LINES+=("$line") ;;
      prerequisite_pr=*) ;;
      *) HEAD_LINES+=("$line") ;;
    esac
  done < "$META"
  {
    for line in "${HEAD_LINES[@]+"${HEAD_LINES[@]}"}"; do printf '%s\n' "$line"; done
    printf 'prerequisite_pr=%s\n' "$URL"
    for line in "${TAIL_LINES[@]+"${TAIL_LINES[@]}"}"; do printf '%s\n' "$line"; done
  } > "$META_TMP" || exit 1
  chmod 0600 "$META_TMP" || exit 1
  fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
  if [ "${#TAIL_LINES[@]}" -gt 0 ]; then
    fm_pr_metadata_identity_parse "$META_TMP" || exit 1
  fi
  fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
  mv -f -- "$META_TMP" "$META" || exit 1
  META_TMP=
  fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
  fm_lock_release "$META_LOCK"
  META_LOCK_HELD=0
  printf 'recorded: state/%s.meta prerequisite_pr=%s\n' "$ID" "$URL"
  exit 0
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

"$FM_ROOT/bin/fm-guard.sh" || true

# Branch identity (see the file header): read the PR's head branch live from
# the forge and refuse unless it is this task's own branch. This is a separate
# query from the pr_head lookup below on purpose, so it never changes what
# that lookup sees. GitLab needs jq because plain glab exposes the source
# branch only inside its JSON output. Neither gh nor jq is otherwise required
# by this script, so their absence degrades the check to a skip rather than a
# refusal, the same best-effort posture the pr_head lookup below already
# takes for a missing gh: an environment that never needed these tools before
# should not newly refuse to record a PR because of this check alone.
PR_BRANCH=
PR_HEAD=
case "$PROVIDER" in
  github)
    if command -v gh >/dev/null 2>&1; then
      if [ -n "$WT" ] && [ -d "$WT" ]; then
        PR_BRANCH=$(cd "$WT" && gh pr view "$URL" --json headRefName -q .headRefName 2>/dev/null) || PR_BRANCH=
      else
        PR_BRANCH=$(gh pr view "$URL" --json headRefName -q .headRefName 2>/dev/null) || PR_BRANCH=
      fi
      if [ -z "$PR_BRANCH" ]; then
        echo "error: could not read PR $URL's head branch to verify it against task $ID" >&2
        exit 1
      fi
    fi
    ;;
  gitlab)
    if command -v jq >/dev/null 2>&1; then
      GITLAB_PROJECT_URL="https://$HOST/$PROJECT_PATH"
      if GITLAB_JSON=$(GITLAB_HOST="$HOST" glab mr view "$NUMBER" -R "$GITLAB_PROJECT_URL" -F json 2>/dev/null) \
        && [ -n "$GITLAB_JSON" ]; then
        PR_BRANCH=$(printf '%s' "$GITLAB_JSON" | jq -r '.source_branch // empty' 2>/dev/null) || PR_BRANCH=
      fi
      if [ -z "$PR_BRANCH" ]; then
        echo "error: could not read PR $URL's head branch to verify it against task $ID" >&2
        exit 1
      fi
      if [ "$ABSORBED_BY" -eq 1 ]; then
        PR_HEAD=$(printf '%s' "$GITLAB_JSON" | jq -r '.sha // empty' 2>/dev/null) || PR_HEAD=
      fi
    fi
    ;;
esac
if [ "$ABSORBED_BY" -eq 0 ] && [ -n "$PR_BRANCH" ] \
  && ! fm_pr_branch_matches_task "$PR_BRANCH" "$ID" "$TASK_BRANCH"; then
  EXPECTED_DESC="fm/$ID (optionally -fixN or -rN)"
  [ -z "$TASK_BRANCH" ] || EXPECTED_DESC="$TASK_BRANCH or $EXPECTED_DESC"
  echo "error: PR $URL head branch '$PR_BRANCH' does not match task $ID's branch ($EXPECTED_DESC); pass --prerequisite to record a PR built for other work" >&2
  exit 1
fi

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field. An ordinary GitLab registration records no
# pr_head because plain glab exposes it only inside JSON and firstmate otherwise
# does not require jq; --absorbed-by already requires jq for exact containment
# and therefore records the combined GitLab head. Other consumers still treat
# pr_head as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
# bin/fm-pr-merge.sh reads a GitLab head live at merge time for the same reason,
# and treats a recorded value that disagrees as stale rather than authoritative.
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ]; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

if [ "$ABSORBED_BY" -eq 1 ]; then
  fm_pr_head_valid "$PR_HEAD" \
    || { echo "error: could not read combined PR $URL's exact head" >&2; exit 1; }
  git -C "$WT" cat-file -e "$PR_HEAD^{commit}" 2>/dev/null \
    || { echo "error: combined PR $URL head $PR_HEAD is not present in the task repository" >&2; exit 1; }
  git -C "$WT" merge-base --is-ancestor "$ORIGINAL_HEAD" "$PR_HEAD" 2>/dev/null \
    || { echo "error: combined PR $URL head does not contain constituent head $ORIGINAL_HEAD" >&2; exit 1; }
fi

META_TMP=
META_LOCK=
META_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
[ "$ABSORBED_BY" -eq 0 ] || [ "$(fm_pr_sha256 "$META")" = "$ORIGINAL_META_HASH" ] \
  || { echo "error: task metadata changed while absorbed binding was being verified" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*|batch_role=*|batch_constituent_branch=*|batch_constituent_head=*|\
    batch_superseded_pr=*|batch_superseded_disposition=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
if [ "$ABSORBED_BY" -eq 1 ]; then
  printf 'batch_role=constituent\n' >> "$META_TMP" || exit 1
  printf 'batch_constituent_branch=%s\n' "$ORIGINAL_BRANCH" >> "$META_TMP" || exit 1
  printf 'batch_constituent_head=%s\n' "$ORIGINAL_HEAD" >> "$META_TMP" || exit 1
  printf 'batch_superseded_pr=%s\n' "$ORIGINAL_URL" >> "$META_TMP" || exit 1
  printf 'batch_superseded_disposition=closed-as-superseded-not-merged\n' >> "$META_TMP" || exit 1
fi
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
# In a secondmate home the registration itself is a captain-facing fact:
# publish the child's PR-ready line with the canonical URL just recorded, so it
# reaches the parent whether or not the mate model appends anything
# (bin/fm-parent-channel-lib.sh). A main home has no channel and this is a
# silent no-op there. The poll is armed either way; a channel that cannot be
# written is reported as actionable, and bin/fm-inactive-reconcile.sh still
# delivers the child's own ready line on the next supervision poll.
READY_LINE="done [key=child-pr-$ID]: child $ID PR ready: $URL"
PR_MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
PR_YOLO=$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)
[ -z "$PR_MODE" ] || READY_LINE="$READY_LINE mode=$(fm_parent_channel_clean_note "$PR_MODE")"
[ -z "$PR_YOLO" ] || READY_LINE="$READY_LINE yolo=$(fm_parent_channel_clean_note "$PR_YOLO")"
READY_RC=0
fm_parent_channel_report "$FM_HOME" "$STATE" "$READY_LINE" || READY_RC=$?
case "$READY_RC" in
  0|1) ;;
  *) printf 'actionable: PR %s is registered but its ready line did not reach the parent channel (rc=%s)\n' "$URL" "$READY_RC" >&2 ;;
esac
printf 'armed: state/%s.check.sh\n' "$ID"
