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
# 13 on 2026-11-05: a done row including the archive, or a merged pull request,
# satisfies; an open row never does; an id with no row, no archive row and no
# pull request is unknown, which blocks and is reported.
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

make_home() {  # <name> <queued-lines> [<done-lines>]; prints the home
  local home=$TMP_ROOT/$1
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_test_tasks_toml "$home/.tasks.toml"
  { printf '# Backlog\n\n## In flight\n\n## Queued\n%s\n\n## Done\n' "$2"
    [ -z "${3:-}" ] || printf '%s\n' "$3"; } > "$home/data/backlog.md"
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
  local home fake ready snap launch
  home=$(make_home agree '- [ ] x-free - nothing to wait for (repo: proj) (kind: ship)
- [ ] x-arch - waits on an archived blocker blocked-by: x-old (repo: proj) (kind: ship)
- [ ] x-done - waits on a done row blocked-by: x-fin (repo: proj) (kind: ship)
- [ ] x-ghost - waits on nothing known blocked-by: x-none (repo: proj) (kind: ship)
- [ ] x-far - waits on another home blocked-by: pc:x-there (repo: proj) (kind: ship)
- [ ] x-open - waits on an open row blocked-by: x-free (repo: proj) (kind: ship)' '- [x] x-fin - delivered (done 2026-11-01)')
  archive "$home" '- [x] x-old - archived (done 2026-10-20)'
  mkdir -p "$home/projects/proj"
  fake=$TMP_ROOT/agree-fake
  mkdir -p "$fake"
  printf '#!/usr/bin/env bash\nprintf "capacity: free_lanes=9 reason=ok lanes=1 target=9\\n"\n' > "$fake/capacity"
  cat > "$fake/spawn" <<'SH'
#!/usr/bin/env bash
echo "spawned $1"
SH
  chmod +x "$fake/capacity" "$fake/spawn"
  ready=$(ready_ids "$home" | sort | tr '\n' ' ')
  [ "$ready" = 'x-arch x-done x-free ' ] || fail "ready list: '$ready'"
  snap=$(FM_HOME=$home "$SNAPSHOT" --json | jq -r '.backlog.records[] | select(.structured and .state == "queued" and (.unresolved_blocker_ids | length) == 0) | .id' | sort | tr '\n' ' ')
  [ "$snap" = "$ready" ] || fail "snapshot unblocked rows '$snap' differ from ready '$ready'"
  launch=$(FM_HOME=$home FM_AUTOLAUNCH_CAPACITY_BIN="$fake/capacity" FM_AUTOLAUNCH_SPAWN_BIN="$fake/spawn" \
    bash "$AUTOLAUNCH" --dry-run 2>&1)
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
  pass 'an unreadable archive withholds the whole ready list'
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

fm_test_run \
  test_archived_blockers_resolve_and_cite_their_prs \
  test_ready_withholds_unknown_and_other_home_blockers \
  test_a_merged_pr_alone_never_clears_an_absent_blocker \
  test_mark_records_the_merged_pr_and_unmark_reverses_it \
  test_ready_autolaunch_and_snapshot_agree \
  test_a_second_run_gives_the_same_result_and_reads_change_nothing \
  test_an_unreadable_archive_withholds_the_whole_ready_list \
  test_the_archive_path_follows_tasks_toml
