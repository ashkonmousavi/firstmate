#!/usr/bin/env bash
# Behavior tests for the shared blocked-by rule (bin/fm-blocked-by-lib.sh) as
# its consumers apply it: bin/fm-tasks-axi.sh ready, bin/fm-autolaunch.sh
# --dry-run, bin/fm-fleet-snapshot.sh --json, and bin/fm-blocked-by.sh.
#
# Oracles: the q-server row captured on 2026-10-31 (x-person-region, blocked by
# x-person-preferences, x-region-registry and x-record-ux-data-compat), whose two
# archived blockers merged as NOT_Q PRs 2978 and 2700 and sit in q-server's done
# archive citing those URLs; the live 2026-11-05 cross-home case (q-server
# x-j17-slice6 blocked by x-spine-workshop-contract, open on the Zenbook while its
# fm/ pull request 1218 merged on 2026-10-19); and the rule fleet-ops set for cut
# 13 as amended on 2026-11-05: with a fresh fleet list, a done or archive
# row or a manual merged-PR mark satisfies; an open row never does; an id with no row, no archive row and no
# pull request is unknown, which blocks and is reported.
# Fleet-list oracle: the four live edges of the 2026-11-05 census whose blocker
# is done or archived in the edge's own home and open in the other one (q-server
# x-j17-slice6, x-j09-basket-approval-build and x-feedback-apps-status, open on
# the Zenbook; q-zenbook x-ai-s5b-sibling-skills, open on the server), and the
# fleet-ops answer of 2026-11-05: open in any home the list covers blocks, and an
# absent or six-hour-old list prints a visible line rather than staying silent.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || fail 'tasks-axi is required for the blocked-by backlog fixtures'
command -v jq >/dev/null 2>&1 || fail 'jq is required for the snapshot fixtures'
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE \
  FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
TMP_ROOT=$(fm_test_tmproot fm-blocked-by)
WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
TOOL="$ROOT/bin/fm-blocked-by.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
AUTOLAUNCH="$ROOT/bin/fm-autolaunch.sh"

PR_2978=https://github.com/ashkonmousavi/NOT_Q/pull/2978
PR_2700=https://github.com/ashkonmousavi/NOT_Q/pull/2700
PR_1218=https://github.com/ashkonmousavi/NOT_Q/pull/1218
PR_1541=https://github.com/ashkonmousavi/NOT_Q/pull/1541
PR_2691=https://github.com/ashkonmousavi/NOT_Q/pull/2691
FLEET_HOMES=pc,x-ux,fleet-ops,q-server,q-zenbook

make_home() {  # <name> <queued-lines> [<done-lines>]; prints the home
  local home=$TMP_ROOT/$1
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_test_tasks_toml "$home/.tasks.toml"
  { printf '# Backlog\n\n## In flight\n\n## Queued\n%s\n\n## Done\n' "$2"
    [ -z "${3:-}" ] || printf '%s\n' "$3"; } > "$home/data/backlog.md"
  fleet_list "$home" local "$(date +%s)" local
  printf '%s\n' "$home"
}

archive() {  # <home> <rows>
  printf '# Done archive\n\n## Archived 2026-11-03\n%s\n' "$2" > "$1/data/done-archive.md"
}

ready_ids() {  # <home>: ids of the ready[N] group only
  FM_HOME=$1 "$WRAPPER" ready | awk '/^ready\[[0-9]+\]/ { on = 1; next } on && /^  [^ ]/ { sub(/^  /, ""); sub(/,.*/, ""); print; next } { on = 0 }'
}

withheld() {  # <home>: id,target,verdict lines of the ready_withheld group
  FM_HOME=$1 "$WRAPPER" ready | awk '/^ready_withheld\[/ { on = 1; next } on && /^  [^ ]/ { sub(/^  /, ""); print; next } { on = 0 }'
}

fleet_list() {  # <home> <self> <generated-epoch> <homes> <row lines as home:id:state ...>
  local home=$1 self=$2 gen=$3 homes=$4 entry
  shift 4
  { printf '# blocked-by fleet rows v1\nself\t%s\ngenerated\t%s\nhomes\t%s\n' "$self" "$gen" "$homes"
    for entry in "$@"; do
      IFS=: read -r h i s <<<"$entry"
      printf 'row\t%s\t%s\t%s\n' "$h" "$i" "$s"
    done; } > "$home/data/blocked-by-fleet-rows.tsv"
}

autolaunch_dry() {  # <home>: autolaunch --dry-run output with fake capacity and spawn
  local fake=$TMP_ROOT/${1##*/}-fake
  mkdir -p "$fake" "$1/projects/proj"
  printf '#!/usr/bin/env bash\nprintf "capacity: free_lanes=9 reason=ok lanes=1 target=9\\n"\n' > "$fake/capacity"
  cat > "$fake/spawn" <<'SH'
#!/usr/bin/env bash
echo "spawned $1"
SH
  chmod +x "$fake/capacity" "$fake/spawn"
  FM_HOME=$1 FM_AUTOLAUNCH_CAPACITY_BIN="$fake/capacity" FM_AUTOLAUNCH_SPAWN_BIN="$fake/spawn" \
    bash "$AUTOLAUNCH" --dry-run 2>&1
}

snapshot_unresolved() {  # <home> <row-id>: that row's unresolved blocker ids, comma-joined
  FM_HOME=$1 "$SNAPSHOT" --json | jq -r --arg id "$2" '.backlog.records[] | select(.id == $id) | .unresolved_blocker_ids | join(",")'
}

fake_gh() {  # <dir>: a gh that answers `pr view <url>` from <dir>/<number>.json and
  # `pr list ... --head <branch>` from <dir>/head-<branch with / as _>.json (else [])
  mkdir -p "$1"
  cat > "$1/gh" <<'SH'
#!/usr/bin/env bash
dir=${0%/*}
printf '%s\n' "$*" >> "$dir/calls"
case "$1 $2" in
  "pr view") f="$dir/${3##*/}.json"; [ -f "$f" ] || exit 1; cat "$f" ;;
  "pr list")
    head=
    while [ "$#" -gt 0 ]; do [ "$1" = --head ] && head=$2; shift; done
    f="$dir/head-${head//\//_}.json"
    if [ -f "$f" ]; then cat "$f"; else printf '[]\n'; fi ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$1/gh"
}

X_PERSON_REGION='- [ ] x-person-region - P1 person region and format blocked-by: x-person-preferences blocked-by: x-region-registry blocked-by: x-record-ux-data-compat (repo: NOT_Q) (kind: ship) (priority: 2) (since 2026-10-31)'

test_archived_blockers_resolve_and_cite_their_prs() {
  local home out
  home=$(make_home person "$X_PERSON_REGION
- [ ] x-person-preferences - One per-person preference (repo: NOT_Q) (kind: ship)")
  archive "$home" "- [x] x-record-ux-data-compat - N4b-R record: land N4b's data compatibility drawings on main $PR_2700 (repo: NOT_Q)
- [x] x-region-registry - P2 region registry: code lists and facts about places $PR_2978 (repo: NOT_Q) (kind: ship)"
  out=$(snapshot_unresolved "$home" x-person-region)
  [ "$out" = x-person-preferences ] || fail "snapshot keeps archived blockers unresolved: '$out'"
  out=$(FM_HOME=$home "$TOOL" verdicts)
  printf '%s\n' "$out" | grep -Fqx "x-person-region	0	x-region-registry	satisfied	archive row $PR_2978" \
    || fail "x-region-registry verdict does not cite PR 2978: $out"
  printf '%s\n' "$out" | grep -Fqx "x-person-region	0	x-record-ux-data-compat	satisfied	archive row $PR_2700" \
    || fail "x-record-ux-data-compat verdict does not cite PR 2700: $out"
  printf '%s\n' "$out" | grep -Fqx 'x-person-region	0	x-person-preferences	blocked	open row' \
    || fail "an open blocker must still block: $out"
  ready_ids "$home" | grep -Fqx x-person-region && fail 'x-person-region is ready while x-person-preferences is open'
  pass 'archived blockers resolve citing PRs 2978 and 2700; the open one still blocks'
}

test_ready_withholds_unknown_and_other_home_blockers() {
  local home ids held
  home=$(make_home unknown '- [ ] x-a - waits blocked-by: x-ghost (kind: ship)
- [ ] x-e - waits blocked-by: q-zenbook:x-z (kind: ship)
- [ ] x-z - local namesake (kind: ship)
- [ ] x-free - no edges (kind: ship)')
  ids=$(ready_ids "$home" | tr '\n' ' ')
  [ "$ids" = 'x-z x-free ' ] || fail "ready lists rows whose blocker is unknown: '$ids'"
  held=$(withheld "$home")
  printf '%s\n' "$held" | grep -Fq 'x-a,x-ghost,unknown,"no row in this home backlog or archive and no recorded mark"' \
    || fail "absent blocker not reported with its evidence: $held"
  printf '%s\n' "$held" | grep -Fq 'x-e,"q-zenbook:x-z",unknown,"names home q-zenbook' \
    || fail "other-home blocker not reported: $held"
  FM_HOME=$home "$WRAPPER" ready | grep -Fqx 'count: 2' || fail 'count: is not rewritten to the remaining rows'
  [ "$(snapshot_unresolved "$home" x-a)" = x-ghost ] || fail 'snapshot clears an unknown blocker'
  [ "$(snapshot_unresolved "$home" x-e)" = q-zenbook:x-z ] || fail 'snapshot clears an other-home blocker'
  pass 'an absent or other-home blocker is unknown: withheld from ready with its evidence, unresolved in the snapshot'
}

test_a_merged_pr_alone_never_clears_an_absent_blocker() {
  local home gh
  home=$(make_home slice6 '- [ ] x-j17-slice6 - J-17 slice 6: first idea in Workshop blocked-by: x-spine-workshop-contract (repo: NOT_Q) (priority: 2) (since 2026-10-14)')
  gh=$TMP_ROOT/slice6-gh
  fake_gh "$gh"
  printf '{"state":"MERGED","url":"%s","headRefName":"fm/x-spine-workshop-contract","mergedAt":"2026-10-19T05:01:45Z"}\n' "$PR_1218" > "$gh/1218.json"
  printf '[{"number":1218,"url":"%s","state":"MERGED","headRefName":"fm/x-spine-workshop-contract","mergedAt":"2026-10-19T05:01:45Z"}]\n' "$PR_1218" > "$gh/head-fm_x-spine-workshop-contract.json"
  PATH="$gh:$PATH" ready_ids "$home" | grep -Fqx x-j17-slice6 \
    && fail 'x-j17-slice6 is ready although its blocker is open on another machine'
  PATH="$gh:$PATH" FM_BLOCKED_BY_GH="$gh/gh" withheld "$home" | grep -Fq 'x-j17-slice6,x-spine-workshop-contract,unknown' \
    || fail 'x-j17-slice6 is not reported as waiting on an unknown blocker'
  [ ! -e "$gh/calls" ] || fail "ready or verdicts looked up a pull request: $(cat "$gh/calls")"
  pass 'a merged fm/ PR alone (PR 1218, blocker open elsewhere) never clears an absent blocker'
}

test_mark_records_the_merged_pr_and_unmark_reverses_it() {
  local home gh out ledger
  home=$(make_home marks '- [ ] x-a - waits blocked-by: x-gone (kind: ship)
- [ ] x-b - waits blocked-by: x-open (kind: ship)
- [ ] x-open - still open (kind: ship)
- [ ] x-c - waits blocked-by: q-zenbook:x-y (kind: ship)')
  gh=$TMP_ROOT/marks-gh
  fake_gh "$gh"
  printf '{"state":"MERGED","url":"%s","headRefName":"fm/x-gone","mergedAt":"2026-11-02T23:45:34Z"}\n' "$PR_2978" > "$gh/2978.json"
  printf '{"state":"OPEN","url":"https://github.com/o/r/pull/7","headRefName":"fm/x-gone","mergedAt":null}\n' > "$gh/7.json"
  ledger=$home/data/blocked-by-marks.tsv
  out=$(FM_HOME=$home FM_BLOCKED_BY_GH="$gh/gh" "$TOOL" mark x-a x-gone --pr https://github.com/o/r/pull/7 2>&1) \
    && fail "an open PR was accepted as a mark: $out"
  printf '%s' "$out" | grep -Fq 'OPEN, not merged' || fail "open PR refusal does not say why: $out"
  out=$(FM_HOME=$home FM_BLOCKED_BY_GH="$gh/gh" "$TOOL" mark x-b x-open --pr "$PR_2978" 2>&1) \
    && fail "a mark was accepted over an open row: $out"
  out=$(FM_HOME=$home FM_BLOCKED_BY_GH="$gh/gh" "$TOOL" mark x-c q-zenbook:x-y --pr "$PR_2978" 2>&1) \
    && fail "a mark was accepted for an other-home edge: $out"
  out=$(FM_HOME=$home FM_BLOCKED_BY_GH="$gh/gh" "$TOOL" mark x-a x-nothing --pr "$PR_2978" 2>&1) \
    && fail "a mark was accepted for an edge the row does not have: $out"
  [ ! -e "$ledger" ] || fail "a refused mark wrote the ledger: $(cat "$ledger")"
  ready_ids "$home" | grep -Fqx x-a && fail 'x-a is ready before any mark'
  FM_HOME=$home FM_BLOCKED_BY_GH="$gh/gh" "$TOOL" mark x-a x-gone --pr "$PR_2978" >/dev/null || fail 'a merged PR mark was refused'
  awk -F '\t' -v url="$PR_2978" '$1 == "mark" && $2 ~ /^[0-9]+$/ && $3 == "x-a" && $4 == "x-gone" && $5 == url && NF == 5 { ok = 1 } END { exit !ok }' "$ledger" \
    || fail "the ledger line does not record the PR: $(cat "$ledger")"
  ready_ids "$home" | grep -Fqx x-a || fail 'x-a is not ready after its blocker was marked merged'
  FM_HOME=$home "$TOOL" verdicts | grep -Fq "x-a	0	x-gone	satisfied	marked $PR_2978 at " || fail 'the verdict does not cite the mark'
  [ "$(snapshot_unresolved "$home" x-a)" = '' ] || fail 'the snapshot ignores the mark'
  cp "$home/data/backlog.md" "$home/data/backlog.before-reopen"
  sed '/^## Queued$/a - [ ] x-gone - reopened follow-up (kind: ship)' "$home/data/backlog.before-reopen" > "$home/data/backlog.md"
  ready_ids "$home" | grep -Fqx x-a && fail 'a mark cleared x-a although x-gone is open again'
  [ "$(snapshot_unresolved "$home" x-a)" = x-gone ] || fail 'the snapshot lets a mark beat an open row'
  mv "$home/data/backlog.before-reopen" "$home/data/backlog.md"
  out=$(FM_HOME=$home FM_BLOCKED_BY_GH="$gh/gh" "$TOOL" mark x-a x-gone --pr "$PR_2978")
  printf '%s' "$out" | grep -Fq 'already marked' || fail "a repeated mark is not a no-op: $out"
  [ "$(wc -l < "$ledger")" -eq 1 ] || fail 'a repeated mark appended a second line'
  FM_HOME=$home "$TOOL" unmark x-a x-gone >/dev/null || fail 'unmark refused a standing mark'
  ready_ids "$home" | grep -Fqx x-a && fail 'x-a is still ready after unmark'
  [ "$(snapshot_unresolved "$home" x-a)" = x-gone ] || fail 'the snapshot keeps the reversed mark'
  [ "$(cut -f1 "$ledger" | tr '\n' ' ')" = 'mark unmark ' ] || fail "unmark did not keep the history: $(cat "$ledger")"
  FM_HOME=$home "$TOOL" unmark x-a x-gone >/dev/null 2>&1 && fail 'unmark accepted an edge with no standing mark'
  pass 'mark records the merged PR, refuses open PRs, open rows and other homes, never beats a reopened row; unmark reverses it'
}

test_ready_autolaunch_and_snapshot_agree() {
  local home ready snap launch
  home=$(make_home agree '- [ ] x-free - nothing to wait for (repo: proj) (kind: ship)
- [ ] x-arch - waits on an archived blocker blocked-by: x-old (repo: proj) (kind: ship)
- [ ] x-done - waits on a done row blocked-by: x-fin (repo: proj) (kind: ship)
- [ ] x-ghost - waits on nothing known blocked-by: x-none (repo: proj) (kind: ship)
- [ ] x-far - waits on another home blocked-by: pc:x-there (repo: proj) (kind: ship)
- [ ] x-open - waits on an open row blocked-by: x-free (repo: proj) (kind: ship)' '- [x] x-fin - delivered (done 2026-11-01)')
  archive "$home" '- [x] x-old - archived (done 2026-10-20)'
  ready=$(ready_ids "$home" | sort | tr '\n' ' ')
  [ "$ready" = 'x-arch x-done x-free ' ] || fail "ready list: '$ready'"
  snap=$(FM_HOME=$home "$SNAPSHOT" --json | jq -r '.backlog.records[] | select(.structured and .state == "queued" and (.unresolved_blocker_ids | length) == 0) | .id' | sort | tr '\n' ' ')
  [ "$snap" = "$ready" ] || fail "snapshot unblocked rows '$snap' differ from ready '$ready'"
  launch=$(autolaunch_dry "$home")
  for id in x-ghost x-far x-open; do
    printf '%s\n' "$launch" | grep -Fq "$id" && fail "autolaunch considered $id, which still waits: $launch"
  done
  for id in x-free x-arch x-done; do
    printf '%s\n' "$launch" | grep -Fq "$id" || fail "autolaunch did not consider ready $id: $launch"
  done
  pass 'ready, autolaunch --dry-run and the snapshot agree on every row'
}

test_a_second_run_gives_the_same_result_and_reads_change_nothing() {
  local home before after one two
  home=$(make_home again "$X_PERSON_REGION
- [ ] x-a - waits blocked-by: x-ghost (kind: ship)")
  archive "$home" "- [x] x-region-registry - registry $PR_2978"
  before=$(cd "$home/data" && sha256sum backlog.md done-archive.md)
  one=$(FM_HOME=$home "$WRAPPER" ready; FM_HOME=$home "$TOOL" verdicts; snapshot_unresolved "$home" x-person-region)
  two=$(FM_HOME=$home "$WRAPPER" ready; FM_HOME=$home "$TOOL" verdicts; snapshot_unresolved "$home" x-person-region)
  [ "$one" = "$two" ] || fail "a second run differs: $one // $two"
  after=$(cd "$home/data" && sha256sum backlog.md done-archive.md)
  [ "$before" = "$after" ] || fail 'a read changed the backlog or archive'
  [ ! -e "$home/data/blocked-by-marks.tsv" ] || fail 'a read wrote the mark ledger'
  pass 'a second run gives the same result and the reads change nothing'
}

test_an_unreadable_archive_withholds_the_whole_ready_list() {
  local home out rc
  [ "$(id -u)" != 0 ] || { pass 'unreadable archive (skipped as root: chmod cannot hide a file)'; return; }
  home=$(make_home unreadable '- [ ] x-a - waits blocked-by: x-old (kind: ship)
- [ ] x-free - no edges (kind: ship)')
  archive "$home" '- [x] x-old - archived'
  chmod 000 "$home/data/done-archive.md"
  out=$(FM_HOME=$home "$WRAPPER" ready 2>&1); rc=$?
  chmod 644 "$home/data/done-archive.md"
  [ "$rc" = 2 ] || fail "ready exited $rc with an unreadable archive: $out"
  printf '%s' "$out" | grep -Fq 'x-free' && fail "ready listed rows while the archive was unreadable: $out"
  printf '%s' "$out" | grep -Fq 'cannot be read' || fail "the refusal does not name the archive: $out"
  chmod 000 "$home/data/done-archive.md"
  out=$(FM_HOME=$home "$SNAPSHOT" --json 2>"$TMP_ROOT/unreadable.err"); rc=$?
  chmod 644 "$home/data/done-archive.md"
  [ "$rc" = 0 ] || fail "the snapshot failed outright on an unreadable archive (exit $rc): $(cat "$TMP_ROOT/unreadable.err")"
  [ "$(printf '%s' "$out" | jq -r '.backlog.records[] | select(.id == "x-a") | .unresolved_blocker_ids | join(",")')" = x-old ] \
    || fail "the snapshot cleared a blocker it could not decide: $out"
  printf '%s' "$out" | jq -e '.backlog.blocked_by_error | test("cannot be read")' >/dev/null \
    || fail "the snapshot does not keep the reason: $(printf '%s' "$out" | jq -c .backlog.blocked_by_error)"
  grep -Fq 'every blocker of' "$TMP_ROOT/unreadable.err" || fail 'the snapshot fallback printed no diagnostic'
  pass 'an unreadable archive withholds the whole ready list; the snapshot stands with every blocker unresolved'
}

LIVE_SERVER_ROWS='- [ ] x-j17-slice6 - J-17 slice 6: first idea in Workshop and journey completion blocked-by: x-spine-workshop-contract (repo: proj) (priority: 2) (since 2026-10-14)
- [ ] x-j09-basket-approval-build - j09 basket execution build: XAI executes one labelled test basket blocked-by: x-spine-cashier-contract (repo: proj) (kind: ship) (since 2026-10-18)
- [ ] x-feedback-apps-status - Apps: connection details and a compact Desk status light blocked-by: x-j17-slice2 (repo: proj) (kind: ship) (since 2026-10-31)
- [ ] x-j17-complete-walk - J-17 complete walk blocked-by: q-zenbook:x-j17-slice2 (repo: proj) (since 2026-10-15)
- [ ] x-free - nothing to wait for (repo: proj) (kind: ship)'
LIVE_SERVER_ARCHIVE="- [x] x-spine-workshop-contract - Spine adoption node workshop-contract (repo: proj) (reported 2026-10-18)
- [x] x-spine-cashier-contract - Spine contract node S20 Cashier $PR_1541 (repo: proj) (merged 2026-10-19)
- [x] x-j17-slice2 - J-17 slice 2: one working paper broker on Apps (repo: proj) (done 2026-10-22)"

live_server() {  # <name>: the q-server fixture
  local home
  home=$(make_home "$1" "$LIVE_SERVER_ROWS")
  archive "$home" "$LIVE_SERVER_ARCHIVE"
  printf '%s\n' "$home"
}

test_the_fleet_list_blocks_the_four_live_cross_home_edges() {
  local server zen id ready held snap launch
  server=$(live_server fleet-server)
  zen=$(make_home fleet-zen '- [ ] x-ai-s5b-sibling-skills - S5b: sibling skills publish from folders blocked-by: x-recipe-publish-from-folders (repo: proj) (kind: ship) (since 2026-10-31)' \
    "- [x] x-recipe-publish-from-folders - Recipe publishes skills from openwebui/skills folders $PR_2691 (repo: proj) (kind: ship) (merged 2026-10-31)")
  rm -f "$server/data/blocked-by-fleet-rows.tsv" "$zen/data/blocked-by-fleet-rows.tsv"
  ready=$(ready_ids "$server" | tr '\n' ' ')
  [ "$ready" = 'x-free ' ] \
    || fail "without a fleet list the own-home archive cannot prove readiness: '$ready'"
  FM_HOME=$server "$WRAPPER" ready | grep -Fqx 'blocked_by_fleet_list: "fleet list absent: visible open rows still block; every other edge is unknown, including local done rows, archive rows and recorded marks"' \
    || fail "ready does not say the fleet list is absent: $(FM_HOME=$server "$WRAPPER" ready)"
  ready_ids "$zen" | grep -Fqx x-ai-s5b-sibling-skills && fail 'without a fleet list the Zenbook done row cannot prove readiness'

  fleet_list "$server" q-server "$(date +%s)" "$FLEET_HOMES" q-zenbook:x-spine-workshop-contract:open \
    q-zenbook:x-spine-cashier-contract:open q-zenbook:x-j17-slice2:open q-server:x-j17-slice6:open q-pc:x-stray:open
  fleet_list "$zen" q-zenbook "$(date +%s)" "$FLEET_HOMES" q-server:x-recipe-publish-from-folders:open \
    q-zenbook:x-recipe-publish-from-folders:done
  ready=$(ready_ids "$server" | tr '\n' ' ')
  [ "$ready" = 'x-free ' ] || fail "ready still lists a row whose blocker is open on the Zenbook: '$ready'"
  ready_ids "$zen" | grep -Fqx x-ai-s5b-sibling-skills && fail 'x-ai-s5b-sibling-skills is ready while its blocker is open on the server'
  held=$(withheld "$server")
  for id in 'x-j17-slice6,x-spine-workshop-contract' 'x-j09-basket-approval-build,x-spine-cashier-contract' \
            'x-feedback-apps-status,x-j17-slice2' 'x-j17-complete-walk,"q-zenbook:x-j17-slice2"'; do
    printf '%s\n' "$held" | grep -Fq "$id,blocked,\"open in q-zenbook per fleet list " \
      || fail "$id is not withheld as open in q-zenbook: $held"
  done
  withheld "$zen" | grep -Fq 'x-ai-s5b-sibling-skills,x-recipe-publish-from-folders,blocked,"open in q-server per fleet list ' \
    || fail "the Zenbook row is not withheld as open on the server: $(withheld "$zen")"
  FM_HOME=$server "$WRAPPER" ready | grep -Fq blocked_by_fleet_list && fail 'a fresh fleet list still prints the absent or stale line'
  for id in x-j17-slice6 x-j09-basket-approval-build x-feedback-apps-status; do
    snap=$(snapshot_unresolved "$server" "$id")
    [ -n "$snap" ] || fail "the snapshot clears $id although its blocker is open on the Zenbook"
  done
  [ "$(snapshot_unresolved "$zen" x-ai-s5b-sibling-skills)" = x-recipe-publish-from-folders ] \
    || fail 'the Zenbook snapshot clears a blocker open on the server'
  launch=$(autolaunch_dry "$server")
  for id in x-j17-slice6 x-j09-basket-approval-build x-feedback-apps-status x-j17-complete-walk; do
    printf '%s\n' "$launch" | grep -Fq "$id" && fail "autolaunch considered $id while its blocker is open on the Zenbook: $launch"
  done
  printf '%s\n' "$launch" | grep -Fq x-free || fail "autolaunch skipped the ready row: $launch"
  pass 'the fleet list holds the four live cross-home edges in ready, autolaunch and the snapshot; without it ready says so'
}

test_a_qualified_edge_resolves_from_the_named_home() {
  local server
  server=$(live_server qualified)
  fleet_list "$server" q-server "$(date +%s)" "$FLEET_HOMES" q-zenbook:x-j17-slice2:done \
    q-zenbook:x-spine-workshop-contract:open q-zenbook:x-spine-cashier-contract:open q-server:x-j17-slice2:open
  ready_ids "$server" | grep -Fqx x-j17-complete-walk || fail 'a done row in the named home does not satisfy q-zenbook:x-j17-slice2'
  ready_ids "$server" | grep -Fqx x-feedback-apps-status \
    || fail "the list's own q-server rows were read over this home's live archive"
  FM_HOME=$server "$TOOL" verdicts | grep -Fq 'x-j17-complete-walk	0	q-zenbook:x-j17-slice2	satisfied	done row in q-zenbook per fleet list ' \
    || fail "the verdict does not cite the fleet list: $(FM_HOME=$server "$TOOL" verdicts)"
  fleet_list "$server" q-server "$(date +%s)" pc,q-server q-zenbook:x-j17-slice2:done
  withheld "$server" | grep -Fq 'x-j17-complete-walk,"q-zenbook:x-j17-slice2",unknown,"names home q-zenbook, which the fleet list from ' \
    || fail "an uncovered home is not unknown: $(withheld "$server")"
  fleet_list "$server" q-server "$(date +%s)" "$FLEET_HOMES" q-zenbook:x-other:open
  withheld "$server" | grep -Fq 'x-j17-complete-walk,"q-zenbook:x-j17-slice2",unknown,"no row in q-zenbook per fleet list ' \
    || fail "a qualified id absent from its home is not unknown: $(withheld "$server")"
  pass 'a <home>:<id> edge resolves from that home: done satisfies, absent or uncovered is unknown'
}

test_a_stale_fleet_list_is_shown_and_never_reopens_an_edge() {
  local server out
  server=$(live_server stale)
  fleet_list "$server" q-server "$(( $(date +%s) - 7 * 3600 ))" "$FLEET_HOMES" q-zenbook:x-spine-workshop-contract:open \
    q-zenbook:x-spine-cashier-contract:open q-zenbook:x-j17-slice2:done
  out=$(FM_HOME=$server "$WRAPPER" ready)
  printf '%s\n' "$out" | grep -Eq '^blocked_by_fleet_list: "fleet list stale: generated [0-9T:-]+Z \(age 7h\), covers pc,x-ux,fleet-ops,q-server,q-zenbook; ' \
    || fail "ready does not show the stale list with its age and homes: $out"
  ready_ids "$server" | grep -Fqx x-j17-slice6 && fail 'a stale list let x-j17-slice6 launch while its blocker was open on the Zenbook'
  withheld "$server" | grep -Fq 'x-j17-complete-walk,"q-zenbook:x-j17-slice2",unknown,"names home q-zenbook; fleet list stale: generated ' \
    || fail "a stale list's done row satisfied a qualified edge: $(withheld "$server")"
  printf 'self\tq-server\nrow\tq-zenbook\tx-j17-slice2\topen\n' > "$server/data/blocked-by-fleet-rows.tsv"
  out=$(FM_HOME=$server "$WRAPPER" ready 2>&1) && fail "ready accepted a fleet list with no generated or homes line: $out"
  printf '%s' "$out" | grep -Fq 'needs self, generated (epoch) and homes lines' || fail "the malformed-list refusal does not say why: $out"
  pass 'a stale list is shown with its age and homes, its open rows still block and its done rows clear nothing; a malformed one is refused'
}

test_the_archive_path_follows_tasks_toml() {
  local home
  home=$(make_home toml '- [ ] x-a - waits blocked-by: x-old (kind: ship)')
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/old/archive.md"\n' > "$home/.tasks.toml"
  archive "$home" '- [x] x-old - in the default place only'
  ready_ids "$home" | grep -Fqx x-a && fail 'the default archive was read although .tasks.toml names another'
  mkdir -p "$home/data/old"
  printf '## Archived 2026-11-01\n- [x] x-old - archived where .tasks.toml says\n' > "$home/data/old/archive.md"
  ready_ids "$home" | grep -Fqx x-a || fail 'the archive named in .tasks.toml was not read'
  pass 'the archive path follows .tasks.toml'
}

test_missing_or_stale_fleet_data_withholds_every_nonopen_edge() {
  local home mode out id gh
  home=$(make_home incomplete '- [ ] wait-done - waits blocked-by: done-id (kind: ship)
- [ ] wait-archive - waits blocked-by: archive-id (kind: scout)
- [ ] wait-mark - waits blocked-by: marked-id (kind: ship)
- [ ] wait-open - waits blocked-by: open-id (kind: ship)
- [ ] wait-qualified - waits blocked-by: local:done-id (kind: ship)
- [ ] wait-remote - waits blocked-by: remote:remote-id (kind: ship)
- [ ] wait-remote-open - waits blocked-by: remote:remote-open-id (kind: ship)
- [ ] open-id - still open (kind: ship)' '- [x] done-id - delivered')
  archive "$home" '- [x] archive-id - archived'
  gh=$TMP_ROOT/incomplete-gh
  fake_gh "$gh"
  printf '{"state":"MERGED","url":"%s"}\n' "$PR_2978" > "$gh/2978.json"
  FM_HOME=$home FM_BLOCKED_BY_GH="$gh/gh" "$TOOL" mark wait-mark marked-id --pr "$PR_2978" >/dev/null \
    || fail 'could not record the manual mark fixture'
  for mode in absent stale; do
    if [ "$mode" = absent ]; then
      rm -f "$home/data/blocked-by-fleet-rows.tsv"
    else
      fleet_list "$home" local "$(( $(date +%s) - 7 * 3600 ))" local,remote remote:remote-id:done remote:remote-open-id:open
    fi
    out=$(FM_HOME=$home "$TOOL" verdicts)
    for id in wait-done wait-archive wait-mark wait-qualified wait-remote; do
      printf '%s\n' "$out" | awk -F '\t' -v row="$id" -v gap="fleet list $mode:" \
        '$1 == row && $4 == "unknown" && index($5, gap) { found = 1 } END { exit !found }' \
        || fail "$mode list cleared $id or lost the gap evidence: $out"
      ready_ids "$home" | grep -Fqx "$id" && fail "$mode list made $id ready"
    done
    printf '%s\n' "$out" | grep -Fq 'wait-open	0	open-id	blocked	open row' \
      || fail "$mode list stopped blocking a visible local open row: $out"
    if [ "$mode" = stale ]; then
      printf '%s\n' "$out" | grep -Fq 'wait-remote-open	0	remote:remote-open-id	blocked	open in remote' \
        || fail "a stale visible remote open row stopped blocking: $out"
    fi
    [ "$(snapshot_unresolved "$home" wait-done)" = done-id ] || fail "$mode snapshot cleared local done work"
    [ "$(snapshot_unresolved "$home" wait-mark)" = marked-id ] || fail "$mode snapshot cleared a recorded mark"
  done
  fleet_list "$home" local "$(date +%s)" local,remote remote:remote-id:done remote:remote-open-id:open
  for id in wait-done wait-archive wait-mark wait-qualified wait-remote; do
    ready_ids "$home" | grep -Fqx "$id" || fail "fresh fleet data did not restore $id"
  done
  pass 'absent or stale fleet data preserves visible blockers and makes every other edge unknown until refreshed'
}

fm_test_run \
  test_missing_or_stale_fleet_data_withholds_every_nonopen_edge \
  test_archived_blockers_resolve_and_cite_their_prs \
  test_ready_withholds_unknown_and_other_home_blockers \
  test_a_merged_pr_alone_never_clears_an_absent_blocker \
  test_mark_records_the_merged_pr_and_unmark_reverses_it \
  test_ready_autolaunch_and_snapshot_agree \
  test_a_second_run_gives_the_same_result_and_reads_change_nothing \
  test_an_unreadable_archive_withholds_the_whole_ready_list \
  test_the_archive_path_follows_tasks_toml \
  test_the_fleet_list_blocks_the_four_live_cross_home_edges \
  test_a_qualified_edge_resolves_from_the_named_home \
  test_a_stale_fleet_list_is_shown_and_never_reopens_an_edge
