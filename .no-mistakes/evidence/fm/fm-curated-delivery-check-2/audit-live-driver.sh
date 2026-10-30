#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EV=~/.no-mistakes/evidence/01M6516DGGA228B9AYMG5Z2CK3
S=$ROOT/.validation-lab
. tests/git-config-helpers.sh
mkdir -p "$S/audit-home/config" "$S/api"
P=06367bd3a7de93e1acea03e9e56b112f07b387f9
BEFORE=$(git rev-parse "$P^")
git --git-dir="$S/origin.git" update-ref refs/heads/curated "$BEFORE"
git clone -q "$S/origin.git" "$S/code"
git -C "$S/code" config user.name Lab
git -C "$S/code" config user.email lab@example.invalid
for h in pc server laptop; do
  git clone -q "$S/origin.git" "$S/$h" 2>/dev/null
  git -C "$S/$h" checkout -q --detach "$BEFORE"
  printf '%s|%s|\n' "$h" "$S/$h" >> "$S/audit-home/config/curated-delivery-homes"
done
cat > "$S/gh-record" <<'GH'
#!/usr/bin/env bash
f=$(mktemp "$AUDIT_API/response.XXXXXX")
gh "$@" > "$f"
rc=$?
cat "$f"
exit "$rc"
GH
chmod +x "$S/gh-record"
export AUDIT_API="$S/api" FM_HOME="$S/audit-home" FM_CURATED_CODE="$S/code" FM_CURATED_REPO=ashkonmousavi/firstmate FM_CURATED_GH="$S/gh-record" FM_CHECK_TIMEOUT=90
printf 'BEFORE: isolated curated and three home HEADs at %s\n' "$BEFORE" | tee "$EV/audit-before.txt"
bin/fm-curated-delivery-check.sh --list | tee -a "$EV/audit-before.txt"
grep -q 'merged PR not on curated: #144 ' "$EV/audit-before.txt"
# A synthetic lab merge has every actual merged PR as a parent. No production ref is changed.
mapfile -t parents < <(jq -rs '[.[].data.repository.pullRequests.nodes[]? | .mergeCommit.oid // empty] | unique[]' "$S"/api/response.*)
for p in "${parents[@]}"; do
  if ! git --git-dir="$S/origin.git" cat-file -e "$p^{commit}" 2>/dev/null; then
    git --git-dir="$S/origin.git" fetch -q https://github.com/ashkonmousavi/firstmate.git "$p"
  fi
done
args=(-p "$BEFORE")
for p in "${parents[@]}"; do args+=(-p "$p"); done
TREE=$(git rev-parse HEAD^{tree})
TIP=$(printf 'Disposable complete-delivery oracle\n' | git --git-dir="$S/origin.git" -c user.name=Lab -c user.email=lab@example.invalid commit-tree "$TREE" "${args[@]}")
git --git-dir="$S/origin.git" update-ref refs/heads/curated "$TIP"
for h in pc server laptop; do
  git -C "$S/$h" fetch -q origin
  git -C "$S/$h" checkout -q --detach "$TIP"
done
bin/fm-curated-delivery-check.sh --list > "$EV/audit-after.txt"
printf 'AFTER: isolated curated and all three homes at %s; audit output bytes=%s\n' "$TIP" "$(wc -c < "$EV/audit-after.txt")" | tee "$EV/audit-after-receipt.txt"
cat "$EV/audit-after.txt"
# Open-main warnings are intentionally retained by the recorded product decision.
! grep -q 'merged PR not on curated:\|HEAD lacks\|incomplete:' "$EV/audit-after.txt"
git -C "$S/server" checkout -q --detach "$BEFORE"
bin/fm-curated-delivery-check.sh --list > "$EV/audit-lagging-home.txt"
cat "$EV/audit-lagging-home.txt"
grep -q 'home server: HEAD lacks merged PRs:.*144' "$EV/audit-lagging-home.txt"
! grep -q 'home pc:\|home laptop:' "$EV/audit-lagging-home.txt"
printf 'LIVE_AUDIT_SUCCESS\n'
