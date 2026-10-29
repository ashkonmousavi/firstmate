#!/usr/bin/env bash
set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
ROOT=$PWD
E=~/.no-mistakes/evidence/01M63G7WF3X155CM0Z0SN1J1EQ
CODE=$ROOT/.gate-live/audit-code
HOME_AUDIT=$ROOT/.gate-live/audit-home
OLD=$(git -C "$CODE" rev-parse origin/curated)
PR144=06367bd3a7de93e1acea03e9e56b112f07b387f9
# Both disposable homes start at the independently fetched curated revision.
for home in home-a home-b; do
  git clone --quiet "$CODE" "$ROOT/.gate-live/$home"
  git -C "$ROOT/.gate-live/$home" -c advice.detachedHead=false checkout -q "$OLD"
done
printf 'home-a|%s/.gate-live/home-a|
home-b|%s/.gate-live/home-b|
' "$ROOT" "$ROOT" > "$HOME_AUDIT/config/curated-delivery-homes"
audit() {
  FM_HOME="$HOME_AUDIT" FM_CURATED_CODE="$CODE" FM_CURATED_REF=lab-curated FM_CURATED_REPO=ashkonmousavi/firstmate FM_CHECK_TIMEOUT=120 "$ROOT/bin/fm-curated-delivery-check.sh" --list > "$E/$1.txt"
}
git -C "$CODE" branch lab-curated "$OLD"
audit audit-both-before
grep -q '^merged PR not on curated: #144 ' "$E/audit-both-before.txt"
grep '^home home-a: HEAD lacks merged PRs: ' "$E/audit-both-before.txt" | grep -qw 144
grep '^home home-b: HEAD lacks merged PRs: ' "$E/audit-both-before.txt" | grep -qw 144
# Re-land the exact change under validation into the disposable code checkout.
git diff 9ff4e445eade0e08fe9e88501e2a575a4ad65041 0395e598dcaa495e4aee2a9fdc18974af63c5e13 | git -C "$CODE" apply
git -C "$CODE" add .
git -C "$CODE" -c user.name='Delivery lab' -c user.email=lab@example.invalid -c commit.gpgsign=false commit -q -m 'Lab re-landing of change under validation' -m "(cherry picked from commit $PR144)"
DELIVERED=$(git -C "$CODE" rev-parse HEAD)
git -C "$CODE" branch -f lab-curated "$DELIVERED"
git -C "$ROOT/.gate-live/home-a" fetch -q origin
git -C "$ROOT/.gate-live/home-a" -c advice.detachedHead=false checkout -q "$DELIVERED"
audit audit-one-home-stale
! grep -q '^merged PR not on curated: #144 ' "$E/audit-one-home-stale.txt"
! grep '^home home-a: HEAD lacks merged PRs: ' "$E/audit-one-home-stale.txt" | grep -qw 144
grep '^home home-b: HEAD lacks merged PRs: ' "$E/audit-one-home-stale.txt" | grep -qw 144
# Deliver to the second home and verify its own missing-PR entry clears too.
git -C "$ROOT/.gate-live/home-b" fetch -q origin
git -C "$ROOT/.gate-live/home-b" -c advice.detachedHead=false checkout -q "$DELIVERED"
audit audit-both-after
! grep -q '^merged PR not on curated: #144 ' "$E/audit-both-after.txt"
! grep '^home .*: HEAD lacks merged PRs: ' "$E/audit-both-after.txt" | grep -qw 144
! grep -q '^home .*: HEAD lacks .*curated commit' "$E/audit-both-after.txt"
{
  printf 'Source oracle: live GitHub merged PR 144; original merge %s\n' "$PR144"
  printf 'Initial curated: %s\nLab re-landing: %s\n' "$OLD" "$DELIVERED"
  for stage in audit-both-before audit-one-home-stale audit-both-after; do
    printf '\n%s (PR 144 and per-home results):\n' "$stage"
    grep -E '^merged PR not on curated: #144 |^home ' "$E/$stage.txt" || true
  done
  printf '\nHistorical PRs and open-main findings from live GitHub remain in full transcripts. No production home was read or changed.\n'
} > "$E/audit-live-summary.txt"
