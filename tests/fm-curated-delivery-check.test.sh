#!/usr/bin/env bash
# Behavior tests for bin/fm-curated-delivery-check.sh.
#
# The check runs against a scratch git repository standing in for the fork
# checkout (origin/curated and a main-only commit), a fake gh that serves fixture
# PR lists, a fake ssh for the remote homes, and a homes file. No case reaches
# GitHub or a real host.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-curated-delivery-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-curated-delivery-check)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FIX="$TMP_ROOT/fix"
CODE="$TMP_ROOT/code"
mkdir -p "$FIX" "$CODE"

git -C "$CODE" init -q -b main
git -C "$CODE" remote add origin "$CODE"
git -C "$CODE" config user.email t@example.com
git -C "$CODE" config user.name t
echo 1 > "$CODE/f"
git -C "$CODE" add f
git -C "$CODE" commit -q -m base
git -C "$CODE" update-ref refs/remotes/origin/curated HEAD
git -C "$CODE" checkout -q -b side
echo 2 > "$CODE/f"
git -C "$CODE" commit -q -am "main-only change (#144)"
MAIN_SHA=$(git -C "$CODE" rev-parse HEAD)
git -C "$CODE" checkout -q main
CURATED_TIP=$(git -C "$CODE" rev-parse origin/curated)

# A local home whose HEAD is the curated tip, and one that lags it.
git clone -q "$CODE" "$TMP_ROOT/home-ok" 2>/dev/null
git -C "$TMP_ROOT/home-ok" checkout -q "$CURATED_TIP" 2>/dev/null
git clone -q "$CODE" "$TMP_ROOT/home-old" 2>/dev/null
git -C "$TMP_ROOT/home-old" checkout -q "$CURATED_TIP" 2>/dev/null

cat > "$FAKEBIN/gh" <<'GH'
#!/usr/bin/env bash
state= base= owner= name= paginate=0
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) paginate=1 ;;
    -F) case "$2" in base=*) base=${2#base=} ;; owner=*) owner=${2#owner=} ;; name=*) name=${2#name=} ;; esac; shift ;;
    -f) case "$2" in *'states: [MERGED]'*) state=merged ;; *'states: [OPEN]'*) state=open ;; esac; shift ;;
  esac
  shift
done
[ -z "${FIXTURE_GH_FAIL:-}" ] || exit 1
[ -z "${FIXTURE_EXPECT_REPO:-}" ] || [ "$owner/$name" = "$FIXTURE_EXPECT_REPO" ] || exit 2
f="$FIXTURE_DIR/$state-$base.json"
[ -f "$f" ] || f="$FIXTURE_DIR/empty.json"
jq -c --argjson paginate "$paginate" '
  map(if has("labels") then .labels = {nodes: .labels} else . end) |
  . as $prs | (length / 100 | ceil | if . == 0 then 1 else . end) as $pages |
  range(0; (if $paginate == 1 then $pages else 1 end)) as $page |
  {data: {repository: {pullRequests: {
    nodes: $prs[$page * 100:($page + 1) * 100],
    pageInfo: {hasNextPage: ($page + 1 < $pages), endCursor: (($page + 1) | tostring)}
  }}}}' "$f"
[ -z "${FIXTURE_GH_HANG:-}" ] || sleep 30
GH
chmod +x "$FAKEBIN/gh"
printf '[]\n' > "$FIX/empty.json"
REAL_GIT=$(command -v git)
export REAL_GIT
cat > "$FAKEBIN/git" <<'GIT'
#!/usr/bin/env bash
if [ -n "${FIXTURE_FETCH_FAIL:-}" ]; then
  for arg in "$@"; do [ "$arg" != fetch ] || exit 1; done
fi
exec "$REAL_GIT" "$@"
GIT
chmod +x "$FAKEBIN/git"

cat > "$FAKEBIN/ssh" <<'SSH'
#!/usr/bin/env bash
while [ "$1" = -o ]; do shift 2; done
host=$1
shift
case "$host" in sleepy) sleep 30 ;; *) bash -c "$*" ;; esac
SSH
chmod +x "$FAKEBIN/ssh"

write_prs() {  # <merged-main-json> <open-main-json>
  printf '%s\n' "$1" > "$FIX/merged-main.json"
  printf '%s\n' "$2" > "$FIX/open-main.json"
  rm -f "$FIX/merged-curated.json"
}
PR144='[{"number":144,"mergeCommit":{"oid":"'"$MAIN_SHA"'"},"title":"one-way steers","url":"https://example.test/pull/144"}]'

printf 'ok|%s|\n' "$TMP_ROOT/home-ok" > "$TMP_ROOT/homes"
: > "$TMP_ROOT/nohomes"

run_check() {  # <out-file> [env...]
  local out=$1
  shift
  env FM_CURATED_REPO=test-owner/firstmate FM_CHECK_TIMEOUT=20 FM_CURATED_CODE="$CODE" FM_CURATED_REF=origin/curated \
    FM_CURATED_HOMES_FILE="$TMP_ROOT/homes" FM_HOME="$TMP_ROOT/emptyhome" \
    FIXTURE_DIR="$FIX" PATH="$FAKEBIN:$PATH" "$@" "$CHECK" --list > "$out" 2>&1
  expect_code 0 "$?" "check exit"
}

test_lists_merged_main_pr_not_on_curated() {
  write_prs "$PR144" '[]'
  run_check "$TMP_ROOT/o1"
  assert_grep "merged PRs not on curated: 144" "$TMP_ROOT/o1" "summary names 144"
  assert_grep "merged PR not on curated: #144" "$TMP_ROOT/o1" "detail names 144"
  pass "curated-delivery: a main-only merged PR is listed"
}

test_clean_is_silent() {
  write_prs '[]' '[]'
  run_check "$TMP_ROOT/o2"
  [ ! -s "$TMP_ROOT/o2" ] || fail "clean state must print nothing: $(cat "$TMP_ROOT/o2")"
  pass "curated-delivery: nothing delivered-missing prints nothing"
}

test_cherry_pick_trailer_counts_as_landed() {
  write_prs "$PR144" '[]'
  git -C "$CODE" commit -q --allow-empty -m "feat: one-way steers" -m "(cherry picked from commit $MAIN_SHA)"
  git -C "$CODE" update-ref refs/remotes/origin/curated HEAD
  run_check "$TMP_ROOT/o3" FM_CURATED_HOMES_FILE="$TMP_ROOT/nohomes"
  [ ! -s "$TMP_ROOT/o3" ] || fail "re-landing by trailer must clear 144: $(cat "$TMP_ROOT/o3")"
  git -C "$CODE" reset -q --hard "$CURATED_TIP"
  git -C "$CODE" update-ref refs/remotes/origin/curated "$CURATED_TIP"
  pass "curated-delivery: a cherry-pick trailer is an equivalent re-landing"
}

test_exception_needs_evidence_and_a_landed_relanding() {
  write_prs "$PR144" '[]'
  mkdir -p "$TMP_ROOT/emptyhome/config"
  local ex="$TMP_ROOT/emptyhome/config/curated-delivery-exceptions"
  printf '144 141\n' > "$ex"
  run_check "$TMP_ROOT/o4"
  assert_grep "merged PRs not on curated: 144" "$TMP_ROOT/o4" "no evidence keeps 144 listed"
  printf '144 141 re-landed as 141\n' > "$ex"
  run_check "$TMP_ROOT/o5"
  assert_grep "merged PRs not on curated: 144" "$TMP_ROOT/o5" "re-landing absent from curated keeps 144 listed"
  printf '[{"number":141,"mergeCommit":{"oid":"%s"},"title":"relanded","url":"https://example.test/pull/141"}]\n' "$CURATED_TIP" > "$FIX/merged-curated.json"
  run_check "$TMP_ROOT/o6"
  [ ! -s "$TMP_ROOT/o6" ] || fail "evidenced exception with landed re-landing must clear: $(cat "$TMP_ROOT/o6")"
  printf '144 base:%s carried by the base commit\n' "$CURATED_TIP" > "$ex"
  rm -f "$FIX/merged-curated.json"
  run_check "$TMP_ROOT/o6b"
  [ ! -s "$TMP_ROOT/o6b" ] || fail "an evidenced base: re-landing on curated must clear: $(cat "$TMP_ROOT/o6b")"
  printf '144 base:%s carried by a commit not on curated\n' "$MAIN_SHA" > "$ex"
  run_check "$TMP_ROOT/o6c"
  assert_grep "merged PRs not on curated: 144" "$TMP_ROOT/o6c" "a base: commit that is not on curated keeps 144 listed"
  rm -f "$ex" "$FIX/merged-curated.json"
  pass "curated-delivery: exceptions need evidence and a re-landing that is on curated"
}

test_every_merged_pr_requires_delivery_evidence() {
  write_prs '[{"number":1,"mergeCommit":{"oid":"'"$MAIN_SHA"'"},"title":"old undelivered work","url":"https://example.test/1"}]' '[]'
  run_check "$TMP_ROOT/old-undelivered-env" FM_CURATED_SINCE_PR=200
  assert_grep 'merged PR not on curated: #1 ' "$TMP_ROOT/old-undelivered-env" "an environment cutoff cannot suppress undelivered PRs"
  printf 'since 200 legacy baseline\n' > "$TMP_ROOT/emptyhome/config/curated-delivery-exceptions"
  run_check "$TMP_ROOT/old-undelivered-file"
  assert_grep 'merged PR not on curated: #1 ' "$TMP_ROOT/old-undelivered-file" "a file cutoff cannot suppress undelivered PRs"
  rm -f "$TMP_ROOT/emptyhome/config/curated-delivery-exceptions"
  pass "curated-delivery: every merged PR requires delivery evidence regardless of number"
}

test_open_pr_to_main_flagged_unless_labeled() {
  write_prs '[]' '[{"number":145,"labels":[],"title":"open","url":"https://example.test/pull/145"},{"number":147,"labels":[{"name":"base-main-ok"}],"title":"ok","url":"https://example.test/pull/147"}]'
  run_check "$TMP_ROOT/o8"
  assert_grep "open PRs to main without base-main-ok: 145" "$TMP_ROOT/o8" "unlabeled open PR flagged"
  assert_no_grep "147" "$TMP_ROOT/o8" "labeled open PR exempt"
  pass "curated-delivery: open PRs on main need the exemption label"
}

test_home_behind_is_flagged_and_remote_is_bounded() {
  write_prs '[]' '[]'
  git -C "$CODE" commit -q --allow-empty -m "curated moves"
  git -C "$CODE" update-ref refs/remotes/origin/curated HEAD
  git -C "$TMP_ROOT/home-old" fetch -q "$CODE" 2>/dev/null
  printf 'old|%s|\nremote-behind|%s|behind\nremote-ok|%s|fine\nremote-slow|~/x|sleepy\n' "$TMP_ROOT/home-old" "$TMP_ROOT/home-old" "$CODE" > "$TMP_ROOT/homes"
  local start=$SECONDS
  run_check "$TMP_ROOT/o9" FM_CHECK_TIMEOUT=12
  [ $((SECONDS - start)) -lt 12 ] || fail "check overran its bound"
  assert_grep "home old: HEAD lacks 1 curated commit(s)" "$TMP_ROOT/o9" "local home behind"
  assert_grep "home remote-behind: HEAD lacks 1 curated commit(s)" "$TMP_ROOT/o9" "remote home behind"
  assert_no_grep "home remote-ok" "$TMP_ROOT/o9" "up-to-date remote home is silent"
  assert_grep "home remote-slow: cannot reach sleepy in time" "$TMP_ROOT/o9" "slow ssh is bounded and reported"
  printf 'ok|%s|\n' "$TMP_ROOT/home-ok" > "$TMP_ROOT/homes"
  git -C "$CODE" reset -q --hard "$CURATED_TIP"
  git -C "$CODE" update-ref refs/remotes/origin/curated "$CURATED_TIP"
  pass "curated-delivery: lagging homes are listed and ssh is bounded"
}

test_gh_failure_is_reported_not_clean() {
  write_prs '[]' '[]'
  run_check "$TMP_ROOT/o10" FIXTURE_GH_FAIL=1
  assert_grep "check incomplete" "$TMP_ROOT/o10" "a failed gh call is not silence"
  pass "curated-delivery: a failed gh call is reported as incomplete"
}

test_all_merged_pages_and_relanding_membership() {
  local base
  for base in main curated; do
    write_prs '[]' '[]'
    jq -n --arg landed "$CURATED_TIP" --arg missing "$MAIN_SHA" '
      [range(1000;1300) | {number: ., mergeCommit: {oid: $landed}, title: "landed", url: "https://example.test/landed"}] +
      [{number: 144, mergeCommit: {oid: $missing}, title: "missing", url: "https://example.test/144"}]' > "$FIX/merged-$base.json"
    run_check "$TMP_ROOT/pages-$base"
    assert_grep 'merged PR not on curated: #144' "$TMP_ROOT/pages-$base" "PR after 300 entries remains visible on $base"
  done
  write_prs "$PR144" '[]'
  jq -n --arg sha "$CURATED_TIP" '
    [range(1000;1300) | {number: ., mergeCommit: {oid: $sha}, title: "landed", url: "https://example.test/landed"}] +
    [{number: 141, mergeCommit: {oid: $sha}, title: "carrier", url: "https://example.test/141"}]' > "$FIX/merged-curated.json"
  printf '144 141 evidenced re-landing\n' > "$TMP_ROOT/emptyhome/config/curated-delivery-exceptions"
  run_check "$TMP_ROOT/pages-carrier"
  [ ! -s "$TMP_ROOT/pages-carrier" ] || fail "late re-landing must count: $(cat "$TMP_ROOT/pages-carrier")"
  rm -f "$TMP_ROOT/emptyhome/config/curated-delivery-exceptions"
  run_check "$TMP_ROOT/pages-timeout" FIXTURE_GH_HANG=1 FM_CHECK_TIMEOUT=5
  assert_grep 'check incomplete' "$TMP_ROOT/pages-timeout" "unfinished enumeration is incomplete"
  pass "curated-delivery: every merged page and late re-landing are considered; timeout is incomplete"
}

test_failed_refresh_suppresses_stale_ancestry() {
  write_prs "$PR144" '[]'
  printf 'lagged|%s|\nremote|~/x|behind\n' "$TMP_ROOT/home-old" > "$TMP_ROOT/homes"
  run_check "$TMP_ROOT/refresh-failed" FIXTURE_FETCH_FAIL=1
  assert_grep 'check incomplete: cannot refresh origin/curated' "$TMP_ROOT/refresh-failed" "failed refresh is incomplete"
  assert_no_grep 'merged PR not on curated:' "$TMP_ROOT/refresh-failed" "stale PR verdict suppressed"
  assert_no_grep 'home lagged:' "$TMP_ROOT/refresh-failed" "stale local home verdict suppressed"
  assert_no_grep 'home remote:' "$TMP_ROOT/refresh-failed" "stale remote home verdict suppressed"
  printf 'ok|%s|\n' "$TMP_ROOT/home-ok" > "$TMP_ROOT/homes"
  pass "curated-delivery: a failed refresh never presents stale ancestry as current"
}

test_lists_merged_main_pr_not_on_curated
test_clean_is_silent
test_cherry_pick_trailer_counts_as_landed
test_exception_needs_evidence_and_a_landed_relanding
test_every_merged_pr_requires_delivery_evidence
test_open_pr_to_main_flagged_unless_labeled
test_home_behind_is_flagged_and_remote_is_bounded
test_gh_failure_is_reported_not_clean

test_all_merged_pages_and_relanding_membership
test_failed_refresh_suppresses_stale_ancestry


test_missing_prs_are_listed_per_home() {
  local kind carrier missing remote_root="$TMP_ROOT/remote home's code"
  ln -s "$TMP_ROOT/home-old" "$remote_root"
  for kind in direct cherry exception-pr exception-base; do
    missing=144
    write_prs "$PR144" '[]'
    if [ "$kind" = direct ]; then
      git -C "$CODE" merge -q --ff-only side
    else
      if [ "$kind" = cherry ]; then
        git -C "$CODE" commit -q --allow-empty -m "carrier" -m "(cherry picked from commit $MAIN_SHA)"
      else
        git -C "$CODE" commit -q --allow-empty -m "carrier"
      fi
    fi
    carrier=$(git -C "$CODE" rev-parse HEAD)
    git -C "$CODE" update-ref refs/remotes/origin/curated "$carrier"
    case "$kind" in
      exception-pr)
        missing='141 144'
        printf '[{"number":141,"mergeCommit":{"oid":"%s"},"title":"carrier","url":"https://example.test/141"}]\n' "$carrier" > "$FIX/merged-curated.json"
        printf '144 141 independently evidenced re-landing\n' > "$TMP_ROOT/emptyhome/config/curated-delivery-exceptions"
        ;;
      exception-base)
        printf '144 base:%s independently evidenced re-landing\n' "$carrier" > "$TMP_ROOT/emptyhome/config/curated-delivery-exceptions"
        ;;
    esac
    printf 'local|%s|\nremote|%s|remote-fixture\n' "$TMP_ROOT/home-old" "$remote_root" > "$TMP_ROOT/homes"
    run_check "$TMP_ROOT/home-prs-$kind"
    assert_no_grep 'merged PR not on curated: #144' "$TMP_ROOT/home-prs-$kind" "$kind carrier delivers 144 to curated"
    assert_grep "home local: HEAD lacks merged PRs: $missing" "$TMP_ROOT/home-prs-$kind" "$kind lists original PR in local home"
    assert_grep "home remote: HEAD lacks merged PRs: $missing" "$TMP_ROOT/home-prs-$kind" "$kind lists original PR in remote home"
    assert_grep "missing home PRs: local=$missing; remote=$missing" "$TMP_ROOT/home-prs-$kind" "$kind summary identifies missing home PRs"
    git -C "$TMP_ROOT/home-old" fetch -q "$CODE"
    git -C "$TMP_ROOT/home-old" checkout -q "$carrier"
    run_check "$TMP_ROOT/home-prs-fixed-$kind"
    [ ! -s "$TMP_ROOT/home-prs-fixed-$kind" ] || fail "$kind delivery to both homes must be silent: $(cat "$TMP_ROOT/home-prs-fixed-$kind")"
    git -C "$TMP_ROOT/home-old" checkout -q "$CURATED_TIP"
    git -C "$CODE" reset -q --hard "$CURATED_TIP"
    git -C "$CODE" update-ref refs/remotes/origin/curated "$CURATED_TIP"
    rm -f "$TMP_ROOT/emptyhome/config/curated-delivery-exceptions"
  done
  printf 'ok|%s|\n' "$TMP_ROOT/home-ok" > "$TMP_ROOT/homes"
  pass "curated-delivery: local and remote PR identities include every equivalent carrier and clear after delivery"
}

test_private_targets_and_missing_configuration() {
  local home="$TMP_ROOT/configured-home"
  mkdir -p "$home/config"
  write_prs '[]' '[]'
  printf 'configured-owner/configured-repo\n' > "$home/config/curated-delivery-repo"
  printf 'configured|%s|\n' "$TMP_ROOT/home-ok" > "$home/config/curated-delivery-homes"
  run_check "$TMP_ROOT/private-config" FM_HOME="$home" FM_CURATED_REPO= FM_CURATED_HOMES_FILE= FIXTURE_EXPECT_REPO=configured-owner/configured-repo
  [ ! -s "$TMP_ROOT/private-config" ] || fail "private target configuration must be consumed: $(cat "$TMP_ROOT/private-config")"
  run_check "$TMP_ROOT/env-config" FM_HOME="$home" FM_CURATED_REPO=override-owner/override-repo FIXTURE_EXPECT_REPO=override-owner/override-repo
  [ ! -s "$TMP_ROOT/env-config" ] || fail "explicit repository selection must override private configuration"
  run_check "$TMP_ROOT/missing-config" FM_HOME="$TMP_ROOT/unconfigured" FM_CURATED_REPO= FM_CURATED_HOMES_FILE=
  assert_grep 'repository is not configured' "$TMP_ROOT/missing-config" "no default personal repository is queried"
  assert_grep 'cannot read homes configuration' "$TMP_ROOT/missing-config" "missing fleet configuration is incomplete"
  pass "curated-delivery: private targets and explicit overrides work; missing targets are incomplete"
}

test_missing_prs_are_listed_per_home
test_private_targets_and_missing_configuration
