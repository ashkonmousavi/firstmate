#!/usr/bin/env bash
# Behavior tests for the idle-capacity report and the supervision predicate's
# idle branch (bin/fm-supervision-lib.sh), and for the four wiring sites that
# must surface it. An idle firstmate home with a full queue used to get no
# watcher, no wake, and no turn; these cases pin the four states that must not
# go quiet again.
#
#   state 1  present + live   the turn-end guard's blocked banner carries the line
#   state 2  present + idle    teardown of the last task prints it, and the
#                              widened predicate reports supervision needed
#   state 3  away + live       the away daemon's catch-all scan buffers it
#   state 4  away + idle       same, with no status file in the home at all
#
# Plus the two silencing/hygiene rules: state/.dispatch-freeze replaces the line
# with FREEZE, and an undated hold with no recheck event reports HOLD_STALE.
#
# Real processes throughout: the installed tasks-axi owns every backlog row, and
# `treehouse` is the one PATH shim, because a worktree pool cannot be built in a
# temp dir. Nothing here reads implementation source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-idle-capacity)
fm_git_identity fmtest fmtest@example.invalid

command -v tasks-axi >/dev/null 2>&1 \
  || fail "tasks-axi is required: these cases drive real backlog rows, never a stub"

# --- fixtures ---------------------------------------------------------------

# A firstmate home shaped enough for the predicate and the report: state/, data/
# with a real backlog, and a fakebin whose `treehouse status` reports a pool of
# the requested size. Echoes the home dir.
#   make_home <name> <available-slots>
make_home() {
  local name=$1 slots=$2 home fakebin
  home="$TMP_ROOT/$name"
  fakebin="$home/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
# Pool listing in treehouse status's own column shape: name, status, path, with
# indented process lines that must never be counted as worktrees.
[ "\${1:-}" = status ] || exit 0
i=1
while [ "\$i" -le $slots ]; do
  printf '%s     available    /pool/%s\n' "\$i" "\$i"
  i=\$((i + 1))
done
printf 'busy  in-use       /pool/busy\n'
printf '      bash (1234), claude (5678)\n'
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

add_ready() {  # <home> <id> [--repo <name>]
  local home=$1 id=$2; shift 2
  tasks-axi add "$id" "ready fixture $id" --kind ship "$@" \
    --file "$home/data/backlog.md" >/dev/null
}

# Register a project by name pointing at a physical repository path, in the
# same "- <name> [<mode>] - <desc>; repository: <path> (added <date>)" shape
# data/projects.md uses (AGENTS.md section 2; bin/fm-project-mode.sh).
register_project() {  # <home> <name> <path>
  printf -- '- %s [no-mistakes] - %s; repository: %s (added 2026-01-01)\n' \
    "$2" "$2" "$3" >> "$1/data/projects.md"
}

add_hold() {  # <home> <id> <reason> [--until <date>]
  local home=$1 id=$2 reason=$3; shift 3
  tasks-axi add "$id" "held fixture $id" --kind ship \
    --file "$home/data/backlog.md" >/dev/null
  tasks-axi hold "$id" --reason "$reason" --kind captain "$@" \
    --file "$home/data/backlog.md" >/dev/null
}

# A hold of a named non-captain kind (external, parked, future), for the
# lane-floor unmet-event-hold cases below.
add_kind_hold() {  # <home> <id> <kind> [--until <date>]
  local home=$1 id=$2 kind=$3; shift 3
  tasks-axi add "$id" "kinded fixture $id" --kind ship \
    --file "$home/data/backlog.md" >/dev/null
  tasks-axi hold "$id" --reason "waiting on a named event" --kind "$kind" "$@" \
    --file "$home/data/backlog.md" >/dev/null
}

# A held item exactly like the captain's own pool-capacity holds: --kind load,
# with the spelling the pipeline itself writes ("pool capacity: dispatch when
# a slot frees ... recheck daily").
add_load_hold() {  # <home> <id> [--until <date>]
  local home=$1 id=$2; shift 2
  tasks-axi add "$id" "capacity fixture $id" --kind ship \
    --file "$home/data/backlog.md" >/dev/null
  tasks-axi hold "$id" \
    --reason "pool capacity: dispatch when a slot frees; recheck daily" \
    --kind load "$@" --file "$home/data/backlog.md" >/dev/null
}

# Backdate a queued row's recorded start date, the only date tasks-axi keeps for
# a held item and therefore the one the stale-hold age is measured from.
backdate_row() {  # <home> <id> <days>
  local home=$1 id=$2 days=$3 when
  when=$(date -d "-${days} days" +%Y-%m-%d 2>/dev/null) \
    || when=$(date -v"-${days}d" +%Y-%m-%d 2>/dev/null) \
    || fail "no portable way to compute a past date on this platform"
  sed -i.bak "s/^\(- \[ \] $id .*\)(since [0-9-]*)/\1(since $when)/" \
    "$home/data/backlog.md"
  rm -f "$home/data/backlog.md.bak"
  tasks-axi show "$id" --file "$home/data/backlog.md" |
    grep -q "created: $when" || fail "backdating $id to $when did not take"
}

report() {  # <home> [root]
  local home=$1
  local root=${2:-$home}
  PATH="$home/fakebin:$PATH" bash -c '
    . "$1/bin/fm-supervision-lib.sh"
    fm_idle_capacity_report "$2/state" "$2/data" "$3"' _ "$ROOT" "$home" "$root"
}

predicate_needed() {  # <home>
  PATH="$home/fakebin:$PATH" bash -c '
    . "$1/bin/fm-supervision-lib.sh"
    fm_supervision_status "$2/state" 300 "$2/data" "$3"
    printf "%s %s\n" "$FM_SUP_NEEDED" "${FM_SUP_IDLE_CAPACITY:-unset}"' \
    _ "$ROOT" "$1" "$1"
}

dispatchable() {  # <home>
  PATH="$1/fakebin:$PATH" bash -c '
    . "$2/bin/fm-supervision-lib.sh"
    fm_dispatchable_work "$1/state" "$1/data" "$1"' _ "$1" "$ROOT"
}

# Replace tasks-axi only inside one fixture with a forwarding wrapper that
# makes the hold-metadata listing unreadable while leaving `ready` healthy.
break_hold_metadata_read() {  # <home>
  local home=$1 real_tasks
  real_tasks=$(command -v tasks-axi)
  cat > "$home/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
case "\${1:-}:\${2:-}:\${3:-}" in
  list:--file:*|list:--state:*|list:--fields:*) exit 65 ;;
esac
exec "$real_tasks" "\$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
}

# --- report shape -----------------------------------------------------------

test_report_counts_and_disposition() {
  local home out
  home=$(make_home report-shape 3)
  add_ready "$home" idle-a
  add_ready "$home" idle-b
  add_hold "$home" idle-h "waiting on the captain" --until 2099-01-01
  : > "$home/state/live-1.meta"
  out=$(report "$home")
  case "$out" in
    *"IDLE CAPACITY: ready=2 held=1 free_slots=3 live=1"*) ;;
    *) fail "expected the counted IDLE CAPACITY header, got: $out" ;;
  esac
  case "$out" in *idle-a*) ;; *) fail "ready ids must be listed, got: $out" ;; esac
  case "$out" in *idle-b*) ;; *) fail "ready ids must be listed, got: $out" ;; esac
  case "$out" in
    *"dispatch, hold with a due date or recheck event, or record the exact blocking rule on the item"*) ;;
    *) fail "the required disposition line is missing, got: $out" ;;
  esac
  pass "report: counts, ready ids, and the disposition line"
}

test_report_frontier_empty() {
  local home out
  home=$(make_home frontier-empty 3)
  add_hold "$home" only-held "waiting on the captain" --until 2099-01-01
  out=$(report "$home")
  [ "$out" = "FRONTIER EMPTY, HELD=1" ] \
    || fail "no ready work with holds must print FRONTIER EMPTY only, got: $out"
  pass "report: FRONTIER EMPTY, HELD=M when ready is empty but holds exist"
}

test_report_silent_when_nothing_applies() {
  local home out
  home=$(make_home nothing-applies 3)
  out=$(report "$home")
  [ -z "$out" ] || fail "an empty backlog must print nothing, got: $out"
  pass "report: silent with neither ready work nor a hold"
}

test_report_fails_soft_on_unreadable_pool() {
  local home out
  home=$(make_home unreadable-pool 3)
  add_ready "$home" idle-a
  out=$(report "$home" "$TMP_ROOT/no-such-pool-root")
  case "$out" in
    *WARN*) ;;
    *) fail "an unreadable pool must print one WARN line, got: $out" ;;
  esac
  case "$out" in
    *"IDLE CAPACITY: ready="*) fail "free slots are unknown; the counted line must not print: $out" ;;
  esac
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] \
    || fail "the soft-fail path must be exactly one line, got: $out"
  pass "report: an unreadable worktree pool degrades to one WARN line"
}

test_report_resolves_named_project_pool() {
  local home out
  home=$(make_home named-project 2)
  add_ready "$home" idle-a --repo proj-x
  register_project "$home" proj-x "$home"
  out=$(report "$home")
  case "$out" in
    *"IDLE CAPACITY: ready=1 held=0 free_slots=2 live=0"*) ;;
    *) fail "a ready item's own named project must resolve to its registered pool, got: $out" ;;
  esac
  pass "report: a ready item's repo field resolves its own project's pool by name"
}

test_report_one_unreadable_project_never_hides_a_readable_sibling() {
  local home out
  home=$(make_home partial-pools 2)
  add_ready "$home" idle-a
  add_ready "$home" idle-gone --repo Gone
  printf -- '- Gone [no-mistakes] - gone; repository: %s/no-such-repo (added 2026-01-01)\n' \
    "$TMP_ROOT" > "$home/data/projects.md"
  out=$(report "$home")
  case "$out" in
    *WARN*) ;;
    *) fail "an unresolvable project among ready projects must warn, got: $out" ;;
  esac
  case "$out" in
    *"Gone: ready=1 free_slots=unknown"*) ;;
    *) fail "the unresolvable project must be named unknown, not silenced, got: $out" ;;
  esac
  case "$out" in
    *"-: ready=1 free_slots=2"*) ;;
    *) fail "a resolvable sibling project must still report its own free slots, got: $out" ;;
  esac
  pass "report: one unresolvable project reports unknown without hiding a readable sibling's own count"
}

# --- freeze -----------------------------------------------------------------

test_freeze_silences_line() {
  local home out
  home=$(make_home freeze-on 3)
  add_ready "$home" idle-a
  printf '%s\n' 'captain paused dispatch for the release' '2099-01-01' \
    > "$home/state/.dispatch-freeze"
  out=$(report "$home")
  [ "$out" = "FREEZE: captain paused dispatch for the release; recheck 2099-01-01" ] \
    || fail "an applying freeze must replace the line, got: $out"
  pass "freeze: the record silences IDLE CAPACITY and prints FREEZE instead"
}

test_freeze_recheck_date_never_auto_releases_captain_pause() {
  local home out
  home=$(make_home freeze-expired 3)
  add_ready "$home" idle-a
  printf '%s\n' 'captain paused dispatch for the release' '2000-01-01' \
    > "$home/state/.dispatch-freeze"
  out=$(report "$home")
  [ "$out" = "FREEZE: captain paused dispatch for the release; recheck due 2000-01-01; explicit release required" ] \
    || fail "a due reminder must preserve the captain pause until explicit release, got: $out"
  pass "freeze: a due recheck survives time and context loss without granting dispatch"
}

test_freeze_supported_release_is_the_only_permission_transition() {
  local home out
  home=$(make_home freeze-release 3)
  add_ready "$home" idle-a
  FM_HOME="$home" "$ROOT/bin/fm-dispatch-freeze.sh" set \
    --reason 'captain paused dispatch' --recheck 2000-01-01 >/dev/null
  out=$(report "$home")
  case "$out" in *FREEZE*) ;; *) fail "the supported set must freeze dispatch, got: $out" ;; esac
  FM_HOME="$home" "$ROOT/bin/fm-dispatch-freeze.sh" release >/dev/null
  out=$(report "$home")
  case "$out" in
    *"IDLE CAPACITY: ready=1"*) ;;
    *) fail "only the supported explicit release must restore dispatchability, got: $out" ;;
  esac
  pass "freeze: supported explicit release is the permission transition"
}

test_freeze_set_rejects_invalid_calendar_date() {
  local home out rc
  home=$(make_home freeze-invalid-date 3)
  if out=$(FM_HOME="$home" "$ROOT/bin/fm-dispatch-freeze.sh" set \
    --reason 'captain paused dispatch' --recheck 2026-02-31 2>&1); then
    fail "an impossible civil date was accepted: $out"
  else
    rc=$?
  fi
  [ "$rc" -eq 2 ] || fail "an impossible civil date must exit 2, got $rc: $out"
  assert_contains "$out" "refused: recheck must be a valid calendar date" \
    "an impossible civil date must be refused explicitly"
  [ ! -e "$home/state/.dispatch-freeze" ] \
    || fail "an impossible civil date must not create a dispatch-freeze record"

  FM_HOME="$home" "$ROOT/bin/fm-dispatch-freeze.sh" set \
    --reason 'captain paused dispatch' --recheck 2028-02-29 >/dev/null \
    || fail "a valid leap-day recheck was refused"
  pass "freeze: set accepts real civil dates and refuses impossible ones"
}

test_freeze_keeps_idle_capacity_false_but_arms_the_recheck() {
  local home verdict
  home=$(make_home freeze-predicate 3)
  add_ready "$home" idle-a
  printf '%s\n' 'captain paused dispatch' '2099-01-01' \
    > "$home/state/.dispatch-freeze"
  verdict=$(predicate_needed "$home")
  [ "$verdict" = "true false" ] \
    || fail "a frozen home with ready work must keep a watcher armed for the recheck at its own until date, got: $verdict"
  pass "freeze: idle-capacity escalation stays false while frozen, but a watcher stays armed for the recheck"
}

test_freeze_with_no_ready_work_needs_no_watcher() {
  local home verdict
  home=$(make_home freeze-empty-predicate 3)
  printf '%s\n' 'captain paused dispatch' '2099-01-01' \
    > "$home/state/.dispatch-freeze"
  verdict=$(predicate_needed "$home")
  [ "$verdict" = "false false" ] \
    || fail "a frozen home with no ready work has nothing to recheck, got: $verdict"
  pass "freeze: an empty queue needs no recheck watcher even while frozen"
}

# --- hold hygiene -----------------------------------------------------------

test_hold_stale_reported() {
  local home out
  home=$(make_home hold-stale 3)
  add_hold "$home" undated-hold "captain has not ruled"
  backdate_row "$home" undated-hold 2
  out=$(report "$home")
  case "$out" in
    *"HOLD_STALE: undated-hold 2d"*) ;;
    *) fail "an undated, event-less hold older than a day must be named, got: $out" ;;
  esac
  pass "hold hygiene: HOLD_STALE names an undated hold with no recheck event"
}

test_hold_with_event_is_not_stale() {
  local home out
  home=$(make_home hold-event 3)
  add_hold "$home" event-hold "dispatch when the release PR lands"
  backdate_row "$home" event-hold 2
  out=$(report "$home")
  case "$out" in
    *HOLD_STALE*) fail "a hold naming a recheck event must not be named, got: $out" ;;
  esac
  pass "hold hygiene: a hold naming a recheck event is left alone"
}

test_hold_with_until_is_not_stale() {
  local home out
  home=$(make_home hold-dated 3)
  add_hold "$home" dated-hold "captain has not ruled" --until 2099-01-01
  backdate_row "$home" dated-hold 2
  out=$(report "$home")
  case "$out" in
    *HOLD_STALE*) fail "a dated hold must not be named stale, got: $out" ;;
  esac
  case "$out" in
    *HOLD_DUE*) fail "a hold whose due date has not arrived must not be named due, got: $out" ;;
  esac
  pass "hold hygiene: a hold carrying a future due date is left alone"
}

test_hold_past_due_reported() {
  local home out predicate
  home=$(make_home hold-due 3)
  add_hold "$home" overdue-hold "captain has not ruled" --until 2000-01-01
  out=$(report "$home")
  case "$out" in
    *"HOLD_DUE: overdue-hold"*"d overdue"*) ;;
    *) fail "a hold whose due date has passed must be reported due, not skipped, got: $out" ;;
  esac
  case "$out" in
    *HOLD_STALE*) fail "a due hold must be reported as due, not also as stale, got: $out" ;;
  esac
  case "$out" in
    *"IDLE CAPACITY: ready=0"*|*"  overdue-hold"*) \
      fail "an expired reminder must not become dispatchable until its owner releases it, got: $out" ;;
  esac
  predicate=$(predicate_needed "$home")
  [ "$predicate" = "true false" ] \
    || fail "a due reminder must keep supervision alive without claiming dispatch capacity, got: $predicate"
  pass "hold hygiene: HOLD_DUE keeps supervision alive without granting dispatch permission"
}

# The due date only schedules a recheck. The owning workflow's explicit unhold
# is the operation that releases a satisfied engineering dependency.
test_expired_hold_becomes_dispatchable_only_after_explicit_unhold() {
  local home out
  home=$(make_home hold-explicit-release 3)
  add_hold "$home" released-hold "engineering dependency must be rechecked" --until 2000-01-01
  tasks-axi unhold released-hold --file "$home/data/backlog.md" >/dev/null \
    || fail "the owning workflow could not explicitly release a satisfied hold"
  out=$(report "$home")
  case "$out" in
    *"IDLE CAPACITY: ready=1"*"released-hold"*) ;;
    *) fail "an explicitly released dependency must become dispatchable, got: $out" ;;
  esac
  pass "hold hygiene: explicit unhold releases a satisfied engineering dependency"
}

test_unreadable_hold_metadata_fails_closed_for_capacity_and_dispatch_enumeration() {
  local home out work
  home=$(make_home hold-metadata-unknown 3)
  add_ready "$home" ready-but-unknown
  break_hold_metadata_read "$home"
  out=$(report "$home")
  case "$out" in
    *"queued rows could not be read"*) ;;
    *) fail "an unreadable hold listing must disclose unknown dispatchability, got: $out" ;;
  esac
  case "$out" in
    *"IDLE CAPACITY: ready="*|*"ready-but-unknown"*)
      fail "unknown hold metadata must not become idle dispatch capacity, got: $out" ;;
  esac
  work=$(dispatchable "$home")
  [ -z "$work" ] \
    || fail "unknown hold metadata must produce no forced-dispatch candidate, got: $work"
  pass "hold hygiene: unreadable permission metadata fails closed without inventing dispatch work"
}

test_hold_due_today_reported() {
  local home out today
  home=$(make_home hold-due-today 3)
  today=$(date +%Y-%m-%d)
  add_hold "$home" today-hold "captain has not ruled" --until "$today"
  out=$(report "$home")
  case "$out" in
    *"HOLD_DUE: today-hold 0d overdue"*) ;;
    *) fail "a hold due exactly today must already be reported due, got: $out" ;;
  esac
  pass "hold hygiene: a hold due exactly today is reported due, matching the freeze boundary"
}

test_fresh_hold_is_not_stale() {
  local home out
  home=$(make_home hold-fresh 3)
  add_hold "$home" fresh-hold "captain has not ruled"
  out=$(report "$home")
  case "$out" in
    *HOLD_STALE*) fail "a hold placed today must not be named yet, got: $out" ;;
  esac
  pass "hold hygiene: a hold younger than a day is not yet stale"
}

# --- held on capacity only ---------------------------------------------------
# 2026-09-05: the fleet sat idle for hours with four items held purely on pool
# capacity (--kind load, --until dated) while slots were free the whole time -
# `tasks-axi ready` reported 0 and this block stayed silent because it counted
# only unblocked queued items. These cases pin the fix: a hold that exists only
# because a slot was scarce at hold time is named the moment a slot frees,
# without ever releasing the hold itself.

test_capacity_held_load_kind_listed() {
  local home out
  home=$(make_home capacity-held-listed 2)
  add_load_hold "$home" cap-load --until 2099-01-01
  out=$(report "$home")
  case "$out" in
    *"IDLE CAPACITY: 1 item(s) held on capacity only while 2 slot(s) are free: cap-load"*) ;;
    *) fail "a --kind load hold with a free slot must be named, got: $out" ;;
  esac
  pass "capacity hold: a --kind load hold with a free slot is listed"
}

test_capacity_held_silent_with_no_free_slots() {
  local home out
  home=$(make_home capacity-held-full 0)
  add_load_hold "$home" cap-load --until 2099-01-01
  out=$(report "$home")
  case "$out" in
    *"held on capacity"*) fail "a --kind load hold with no free slot must stay silent, got: $out" ;;
  esac
  pass "capacity hold: a --kind load hold with no free slot stays silent"
}

test_capacity_held_reason_phrase_listed_under_other_kind() {
  local home out
  home=$(make_home capacity-held-phrase 2)
  add_hold "$home" cap-phrase "pool capacity: dispatch when a slot frees" --until 2099-01-01
  out=$(report "$home")
  case "$out" in
    *"IDLE CAPACITY: 1 item(s) held on capacity only while 2 slot(s) are free: cap-phrase"*) ;;
    *) fail "a hold reason naming a capacity phrase must be named regardless of kind, got: $out" ;;
  esac
  pass "capacity hold: a hold reason naming a capacity/slot phrase is listed even under --kind captain"
}

test_capacity_held_captain_kind_not_listed() {
  local home out
  home=$(make_home capacity-held-captain 2)
  add_hold "$home" cap-captain "waiting on the captain" --until 2099-01-01
  out=$(report "$home")
  case "$out" in
    *"held on capacity"*) fail "a --kind captain hold with an unrelated reason must never be named, got: $out" ;;
  esac
  pass "capacity hold: a --kind captain hold with no capacity phrase is never listed"
}

capacity_escalate_once() {  # <home>
  PATH="$1/fakebin:$PATH" bash -c '
    . "$2/bin/fm-supervision-lib.sh"
    fm_idle_capacity_compute "$1/state" "$1/data" "$1"
    if fm_idle_capacity_should_escalate "$1/state"; then
      echo escalate
      fm_idle_capacity_mark_escalated "$1/state"
    else
      echo dedup
    fi' _ "$1" "$ROOT"
}

test_capacity_held_escalates_once_per_unchanged_tuple() {
  local home r1 r2
  home=$(make_home capacity-held-dedupe 2)
  add_load_hold "$home" cap-load --until 2099-01-01
  r1=$(capacity_escalate_once "$home")
  r2=$(capacity_escalate_once "$home")
  [ "$r1" = escalate ] || fail "a fresh capacity hold with a free slot must escalate, got: $r1"
  [ "$r2" = dedup ] || fail "an unchanged capacity-held tuple must not escalate twice, got: $r2"
  pass "capacity hold: escalation dedupe fires once per unchanged tuple, matching the ready-work dedupe"
}

test_capacity_held_needs_supervision_with_zero_ready() {
  local home verdict
  home=$(make_home capacity-held-predicate 2)
  add_load_hold "$home" cap-load --until 2099-01-01
  verdict=$(predicate_needed "$home")
  [ "$verdict" = "true true" ] \
    || fail "a fully-held queue with a capacity hold and a free slot must still need supervision, got: $verdict"
  pass "capacity hold: a capacity-only hold with a free slot needs supervision even when nothing is ready"
}

# --- state 2: present + idle (the widened predicate) ------------------------

test_predicate_true_on_idle_capacity() {
  local home verdict
  home=$(make_home predicate-idle 2)
  add_ready "$home" idle-a
  verdict=$(predicate_needed "$home")
  [ "$verdict" = "true true" ] \
    || fail "ready work with a free slot must need supervision, got: $verdict"
  pass "state 2: an idle home with ready work and a free slot needs supervision"
}

test_predicate_false_when_both_false() {
  local home verdict
  home=$(make_home predicate-both-false 0)
  add_ready "$home" idle-a
  verdict=$(predicate_needed "$home")
  [ "$verdict" = "false false" ] \
    || fail "ready work with no free slot must not need supervision, got: $verdict"
  home=$(make_home predicate-empty-queue 3)
  verdict=$(predicate_needed "$home")
  [ "$verdict" = "false false" ] \
    || fail "no work and no ready item must not need supervision, got: $verdict"
  pass "state 2: the predicate stays false when in-flight work and idle capacity both are"
}

test_predicate_unchanged_when_work_in_flight() {
  local home verdict
  home=$(make_home predicate-in-flight 0)
  : > "$home/state/live-1.meta"
  verdict=$(predicate_needed "$home")
  [ "$verdict" = "true false" ] \
    || fail "in-flight work must still carry the predicate on its own, got: $verdict"
  pass "state 2: in-flight work still carries the predicate without the idle branch"
}

# --- concurrency cap ---------------------------------------------------------

test_cap_default_is_thirteen() {
  local home out i
  home=$(make_home cap-default 3)
  add_ready "$home" idle-a
  for i in $(seq 1 12); do : > "$home/state/live-$i.meta"; done
  out=$(report "$home")
  case "$out" in
    *"IDLE CAPACITY: ready=1"*) ;;
    *) fail "12 live workers must still be under the default cap of 13, got: $out" ;;
  esac
  pass "concurrency cap: the default of 13 applies with no config/concurrency-cap file"
}

test_cap_at_configured_value_suppresses_the_line() {
  local home out i
  home=$(make_home cap-at-limit 3)
  add_ready "$home" idle-a
  printf '2\n' > "$home/config/concurrency-cap"
  for i in 1 2; do : > "$home/state/live-$i.meta"; done
  out=$(report "$home")
  [ -z "$out" ] \
    || fail "live work at the configured cap must print no idle-capacity line, got: $out"
  pass "concurrency cap: no line prints once live workers reach the configured cap"
}

test_cap_under_configured_value_still_reports() {
  local home out
  home=$(make_home cap-under-limit 3)
  add_ready "$home" idle-a
  printf '2\n' > "$home/config/concurrency-cap"
  : > "$home/state/live-1.meta"
  out=$(report "$home")
  case "$out" in
    *"IDLE CAPACITY: ready=1 held=0 free_slots=3 live=1"*) ;;
    *) fail "one live worker under a cap of 2 must still report idle capacity, got: $out" ;;
  esac
  pass "concurrency cap: still reports while under the configured cap"
}

test_cap_malformed_file_falls_back_to_default() {
  local home out
  home=$(make_home cap-malformed 3)
  add_ready "$home" idle-a
  printf 'not-a-number\n' > "$home/config/concurrency-cap"
  out=$(report "$home")
  case "$out" in
    *"IDLE CAPACITY: ready=1"*) ;;
    *) fail "a malformed cap file must fall back to the default rather than fail closed, got: $out" ;;
  esac
  pass "concurrency cap: a malformed config value falls back to the default of 13"
}

test_cap_zero_blocks_idle_capacity_with_no_in_flight_work() {
  local home verdict
  home=$(make_home cap-zero 3)
  add_ready "$home" idle-a
  printf '0\n' > "$home/config/concurrency-cap"
  verdict=$(predicate_needed "$home")
  [ "$verdict" = "false false" ] \
    || fail "a cap of zero with no in-flight work must block idle-capacity dispatch entirely, got: $verdict"
  pass "concurrency cap: a cap of zero blocks idle-capacity when nothing is already running"
}

# --- state 1: present + live (the turn-end guard) ---------------------------

install_guard_home() {  # <home>
  local dir=$1 f
  mkdir -p "$dir/bin" "$dir/docs"
  for f in fm-turnend-guard.sh fm-operational-input.sh fm-supervision-instructions.sh \
    fm-harness.sh fm-primary-scope-lib.sh fm-supervision-lib.sh fm-wake-lib.sh \
    fm-hook-host-lib.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-operational-input.sh" \
    "$dir/bin/fm-supervision-instructions.sh" "$dir/bin/fm-harness.sh"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
}

test_guard_banner_names_idle_capacity() {
  local home out rc
  home=$(make_home guard-live 3)
  install_guard_home "$home"
  add_ready "$home" idle-a
  : > "$home/state/live-1.meta"
  set +e
  out=$(printf '{"stop_hook_active":false,"session_id":"s1"}' |
    PATH="$home/fakebin:$PATH" FM_HOME="$home" "$home/bin/fm-turnend-guard.sh" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a home with work and no watcher must block the turn (rc=$rc): $out"
  case "$out" in
    *"IDLE CAPACITY: ready=1 held=0 free_slots=3 live=1"*) ;;
    *) fail "the blocked banner must carry the idle-capacity line, got: $out" ;;
  esac
  case "$out" in
    *"●  IDLE CAPACITY"*) ;;
    *) fail "the line must be rendered in the banner's own style, got: $out" ;;
  esac
  pass "state 1: the turn-end guard's blocked banner carries the idle-capacity line"
}

test_guard_banner_names_idle_only_need() {
  local home out rc
  home=$(make_home guard-idle-only 3)
  install_guard_home "$home"
  add_ready "$home" idle-a
  set +e
  out=$(printf '{"stop_hook_active":false,"session_id":"s1"}' |
    PATH="$home/fakebin:$PATH" FM_HOME="$home" "$home/bin/fm-turnend-guard.sh" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || fail "ready work with a free slot and no watcher must block the turn (rc=$rc): $out"
  case "$out" in
    *"Ready work could be dispatched into a free slot right now"*) ;;
    *) fail "the banner must name idle capacity as the reason, got: $out" ;;
  esac
  pass "state 1: idle capacity alone blocks a blind turn end and names itself"
}

test_guard_silent_without_idle_capacity() {
  local home out rc
  home=$(make_home guard-quiet 0)
  install_guard_home "$home"
  add_ready "$home" idle-a
  set +e
  out=$(printf '{"stop_hook_active":false,"session_id":"s1"}' |
    PATH="$home/fakebin:$PATH" FM_HOME="$home" "$home/bin/fm-turnend-guard.sh" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a home with no free slot must let the turn end (rc=$rc): $out"
  pass "state 1: a full pool with no in-flight work still lets the turn end"
}

test_guard_banner_names_capacity_held() {
  local home out rc
  home=$(make_home guard-capacity-held 2)
  install_guard_home "$home"
  add_load_hold "$home" cap-load --until 2099-01-01
  set +e
  out=$(printf '{"stop_hook_active":false,"session_id":"s1"}' |
    PATH="$home/fakebin:$PATH" FM_HOME="$home" "$home/bin/fm-turnend-guard.sh" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || fail "a capacity-only hold with a free slot and no live watcher must block the turn (rc=$rc): $out"
  case "$out" in
    *"IDLE CAPACITY: 1 item(s) held on capacity only while 2 slot(s) are free: cap-load"*) ;;
    *) fail "the blocked banner must carry the held-on-capacity line, got: $out" ;;
  esac
  pass "state 1: the turn-end guard blocks and names a capacity-only hold sitting on a free slot"
}

# --- state 2: present + idle (teardown of the last task) --------------------

make_teardown_home() {  # <name> <available-slots>
  local home=$1 slots=$2 dir fakebin
  dir=$(make_home "$home" "$slots")
  fakebin="$dir/fakebin"
  # treehouse also serves teardown's own `return`; the pool listing above is the
  # only subcommand these cases read.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/no-mistakes"
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/_seed" 2>/dev/null
  git -C "$dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$dir/_seed" push -q origin main
  rm -rf "$dir/_seed"
  git clone -q "$dir/origin.git" "$dir/project"
  git -C "$dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$dir/project" worktree add -q -b fm/task-t1 "$dir/wt" main
  touch "$dir/state/.last-watcher-beat"
  printf '%s\n' "$dir"
}

test_teardown_prints_idle_capacity() {
  local home out rc
  home=$(make_teardown_home teardown-idle 4)
  add_ready "$home" idle-a
  tasks-axi add task-t1 "teardown fixture" --kind ship \
    --file "$home/data/backlog.md" >/dev/null
  tasks-axi start task-t1 --file "$home/data/backlog.md" >/dev/null
  fm_write_meta "$home/state/task-t1.meta" \
    "window=firstmate:fm-task-t1" \
    "endpoint_task_id=task-t1" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "kind=ship" \
    "mode=local-only" \
    "spawn_gen=idle-capacity-test-task-t1"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$home/fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" task-t1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "teardown of landed local-only work must succeed (rc=$rc): $out"
  case "$out" in
    *"IDLE CAPACITY: ready=1 held=0 free_slots=4 live=0"*) ;;
    *) fail "teardown of the last task must report the idle home, got: $out" ;;
  esac
  pass "state 2: teardown of the last task prints the idle-capacity line"
}

test_teardown_prints_capacity_held() {
  local home out rc
  home=$(make_teardown_home teardown-capacity-held 4)
  add_load_hold "$home" cap-load --until 2099-01-01
  tasks-axi add task-t1 "teardown fixture" --kind ship \
    --file "$home/data/backlog.md" >/dev/null
  tasks-axi start task-t1 --file "$home/data/backlog.md" >/dev/null
  fm_write_meta "$home/state/task-t1.meta" \
    "window=firstmate:fm-task-t1" \
    "endpoint_task_id=task-t1" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "kind=ship" \
    "mode=local-only" \
    "spawn_gen=idle-capacity-test-task-t1-capacity"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$home/fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" task-t1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "teardown of landed local-only work must succeed (rc=$rc): $out"
  case "$out" in
    *"IDLE CAPACITY: 1 item(s) held on capacity only while 4 slot(s) are free: cap-load"*) ;;
    *) fail "teardown of the last task must report the capacity-only hold, got: $out" ;;
  esac
  pass "state 2: teardown of the last task prints the held-on-capacity line, even with nothing ready"
}

# --- states 3 and 4: away mode ----------------------------------------------

# Drive the daemon's real housekeeping scan in library mode, which is how the
# daemon suites exercise it, and read the escalation buffer it writes.
run_away_scan() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" \
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_ROOT_OVERRIDE="$home" \
  FM_ESCALATE_BATCH_SECS=99999 FM_HEARTBEAT_SCAN_SECS=0 \
    bash -c '
      # shellcheck disable=SC1090
      . "$1/bin/fm-supervise-daemon.sh"
      housekeeping "$2/state"' _ "$ROOT" "$home"
}

test_away_live_scan_buffers_idle_capacity() {
  local home
  home=$(make_home away-live 3)
  cp -R "$ROOT/bin" "$home/bin"
  add_ready "$home" idle-a
  : > "$home/state/live-1.meta"
  printf 'working: still going\n' > "$home/state/live-1.status"
  : > "$home/state/.afk"
  run_away_scan "$home" >/dev/null 2>&1 || true
  grep -q "IDLE CAPACITY: ready=1 held=0 free_slots=3 live=1" \
    "$home/state/.subsuper-escalations" \
    || fail "the away scan must buffer the idle-capacity line: $(cat "$home/state/.subsuper-escalations" 2>/dev/null)"
  pass "state 3: away + live buffers the idle-capacity line as an escalation"
}

test_away_idle_scan_buffers_idle_capacity() {
  local home
  home=$(make_home away-idle 3)
  cp -R "$ROOT/bin" "$home/bin"
  add_ready "$home" idle-a
  : > "$home/state/.afk"
  [ -z "$(find "$home/state" -maxdepth 1 -name '*.status' -print -quit)" ] \
    || fail "state 4 must have no status file at all"
  run_away_scan "$home" >/dev/null 2>&1 || true
  grep -q "IDLE CAPACITY: ready=1 held=0 free_slots=3 live=0" \
    "$home/state/.subsuper-escalations" \
    || fail "an away home with no status file at all must still buffer the line: $(cat "$home/state/.subsuper-escalations" 2>/dev/null)"
  pass "state 4: away + idle still buffers the line with no status file to scan"
}

test_away_scan_escalates_idle_capacity_once_per_unchanged_tuple() {
  local home count
  home=$(make_home away-idle-repeat 3)
  cp -R "$ROOT/bin" "$home/bin"
  add_ready "$home" idle-a
  : > "$home/state/.afk"
  run_away_scan "$home" >/dev/null 2>&1 || true
  run_away_scan "$home" >/dev/null 2>&1 || true
  count=$(grep -c "IDLE CAPACITY: ready=1 held=0 free_slots=3 live=0" \
    "$home/state/.subsuper-escalations" 2>/dev/null || true)
  [ "$count" -eq 1 ] \
    || fail "an unchanged (ready ids, free counts) tuple must escalate once, not once per scan (saw $count): $(cat "$home/state/.subsuper-escalations" 2>/dev/null)"
  pass "away scan: an unchanged idle-capacity tuple escalates once across repeated scans, not once per scan"
}

test_away_idle_scan_buffers_capacity_held() {
  local home
  home=$(make_home away-capacity-held 3)
  cp -R "$ROOT/bin" "$home/bin"
  add_load_hold "$home" cap-load --until 2099-01-01
  : > "$home/state/.afk"
  run_away_scan "$home" >/dev/null 2>&1 || true
  grep -q "IDLE CAPACITY: 1 item(s) held on capacity only while 3 slot(s) are free: cap-load" \
    "$home/state/.subsuper-escalations" \
    || fail "the away scan must buffer the held-on-capacity line even with nothing ready: $(cat "$home/state/.subsuper-escalations" 2>/dev/null)"
  pass "away scan: an idle home with a capacity-only hold and free slots buffers the held-on-capacity line"
}

# --- lane floor -------------------------------------------------------------
# The captain's floor on running lanes (config/lane-floor) and the broader
# dispatchable-work read behind it. These pin the two halves the idle-capacity
# block above cannot see: work held for a reason other than the captain, and
# openspec Changes carrying unticked boxes in a registered project clone.

# A registered project clone with one openspec Change. Echoes nothing; the
# Change's tasks.md gets <open> unticked and one ticked box.
make_change() {  # <home> <project> <change> <open-boxes>
  local home=$1 project=$2 change=$3 open=$4 dir i
  dir="$home/projects/$project/openspec/changes/$change"
  mkdir -p "$dir"
  {
    printf '# Tasks\n\n## 1. Work\n\n'
    printf -- '- [x] 1.0 already landed\n'
    i=1
    while [ "$i" -le "$open" ]; do
      printf -- '- [ ] 1.%s still open\n' "$i"
      i=$((i + 1))
    done
  } > "$dir/tasks.md"
  grep -q "repository: $home/projects/$project" "$home/data/projects.md" 2>/dev/null \
    || register_project "$home" "$project" "$home/projects/$project"
}

# A held backlog item whose title names Change <change>, for the lane floor's
# held-record match. Reuses add_kind_hold's kind/until shape.
add_change_hold() {  # <home> <id> <change> <kind> [--until <date>]
  local home=$1 id=$2 change=$3 kind=$4; shift 4
  tasks-axi add "$id" "carries the $change Change" --kind ship \
    --file "$home/data/backlog.md" >/dev/null
  tasks-axi hold "$id" --reason "waiting on a named event" --kind "$kind" "$@" \
    --file "$home/data/backlog.md" >/dev/null
}

# A backlog item whose title names Change <change>, blocked by a fresh
# still-open blocker item, for the lane floor's blocked-record match.
add_change_blocked() {  # <home> <id> <change> <blocker-id>
  local home=$1 id=$2 change=$3 blocker=$4
  tasks-axi add "$blocker" "blocker for $id" --kind ship \
    --file "$home/data/backlog.md" >/dev/null
  tasks-axi add "$id" "carries the $change Change" --kind ship \
    --file "$home/data/backlog.md" >/dev/null
  tasks-axi block "$id" --by "$blocker" --file "$home/data/backlog.md" >/dev/null
}

# A reconciled-current-state stub for the productive count. bin/fm-crew-state.sh
# reads a real pane, a real backend endpoint, and a real pipeline run, none of
# which can be built in a temp dir - so it is the second shim in this file for
# exactly the reason `treehouse` is the first, and FM_LANE_FLOOR_CREW_STATE is
# the lib's own seam for it. A home with no stub leaves the seam pointing at a
# path that does not exist, which is the unreadable-reconciler case itself.
make_crew_state_stub() {  # <home>
  local home=$1
  mkdir -p "$home/crewstate"
  cat > "$home/fakebin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
line="$home/crewstate/\${1:-}"
[ -f "\$line" ] || exit 1
cat "\$line"
SH
  chmod +x "$home/fakebin/fm-crew-state.sh"
}

# One lane whose RECONCILED state is <state> from source <source>, with an
# optional status-log line whose newest verb deliberately disagrees.
add_lane() {  # <home> <id> <state> <source> [status-line]
  local home=$1 id=$2 state=$3 source=$4 status=${5:-}
  make_crew_state_stub "$home"
  printf 'state: %s · source: %s · fixture\n' "$state" "$source" > "$home/crewstate/$id"
  : > "$home/state/$id.meta"
  [ -n "$status" ] && printf '%s\n' "$status" > "$home/state/$id.status"
  return 0
}

lane_floor_report() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" \
  FM_LANE_FLOOR_CREW_STATE="$home/fakebin/fm-crew-state.sh" bash -c '
    . "$1/bin/fm-supervision-lib.sh"
    fm_lane_floor_report "$2/state" "$2/data" "$2" "$2/config"' _ "$ROOT" "$home"
}

# The same call with tasks-axi removed from PATH entirely, so the backlog read
# genuinely fails rather than being stubbed out.
lane_floor_report_without_tasks_axi() {  # <home>
  local home=$1
  PATH="$home/fakebin:/usr/bin:/bin" \
  FM_LANE_FLOOR_CREW_STATE="$home/fakebin/fm-crew-state.sh" bash -c '
    . "$1/bin/fm-supervision-lib.sh"
    fm_lane_floor_report "$2/state" "$2/data" "$2" "$2/config"' _ "$ROOT" "$home"
}

# Proves the breach line appears from work the idle-capacity block cannot see,
# and that a captain-kind hold is the one thing it refuses to count.
test_lane_floor_counts_non_captain_work_only() {
  local home out
  home=$(make_home lane-floor-counts 3)
  make_change "$home" proj alpha 2
  add_hold "$home" captain-call "waiting on the captain to choose a vendor"
  add_load_hold "$home" cap-held
  add_lane "$home" live-1 working pane
  out=$(lane_floor_report "$home")
  case "$out" in
    *"LANE FLOOR: productive=1 floor=10 dispatchable=2"*) ;;
    *) fail "expected the counted LANE FLOOR header, got: $out" ;;
  esac
  case "$out" in
    *"openspec proj:alpha:2"*) ;;
    *) fail "an openspec Change with open boxes must be listed, got: $out" ;;
  esac
  case "$out" in
    *"backlog cap-held"*) ;;
    *) fail "a hold whose kind is not captain is firstmate's own to dispatch, got: $out" ;;
  esac
  case "$out" in
    *captain-call*) fail "a captain-kind hold must never be counted as dispatchable: $out" ;;
  esac
  pass "lane floor: the breach counts openspec Changes and non-captain holds, never a captain hold"
}

# A prepared branch waiting for the validation queue is ready but not active,
# while a no-mistakes run is the validation work currently using a slot.
test_lane_floor_reports_prepared_waiters_and_live_validation_separately() {
  local home out
  home=$(make_home lane-floor-validation-counts 5)
  make_change "$home" proj alpha 1
  add_lane "$home" waiter-1 paused status-log 'paused: prepared, validation slots full'
  add_lane "$home" waiter-2 paused status-log 'paused: prepared, validation slots full'
  add_lane "$home" validator working run-step 'working: no-mistakes run is running'
  out=$(lane_floor_report "$home")
  case "$out" in
    *"VALIDATION: waiting-for-slot=2 live-validation=1"*) ;;
    *) fail "the lane-floor report must distinguish prepared validation waiters from live validation, got: $out" ;;
  esac
  case "$out" in
    *"active=1 prepared=2"*) ;;
    *) fail "prepared validation waiters must not inflate the active count: $out" ;;
  esac
  pass "lane floor: prepared validation waiters and live validation are reported separately"
}

test_research_first_allows_a_bounded_fair_comparison_for_an_unresolved_material_criterion() {
  local skill
  skill="$ROOT/.agents/skills/research-first-decisions/SKILL.md"
  grep -Fq 'may authorize a bounded local comparison before selection' "$skill" \
    || fail "research-first must allow an unresolved material criterion to use a bounded comparison"
  grep -Fq 'identical inputs, versions, conditions, and predeclared criterion' "$skill" \
    || fail "research-first must require fair comparison conditions"
  grep -Fq 'the decision it changed' "$skill" \
    || fail "research-first must preserve the decision changed by a comparison"
  pass "research-first: an unresolved material criterion may use a bounded fair comparison"
}

# An external, parked, or future hold whose named event has not fired yet is
# not dispatchable and would breach the floor forever if counted; a load hold
# still counts. Under the captain-approved reminder contract, an expired date
# triggers re-evaluation but does not prove the named event occurred, so the
# external hold remains excluded until its owner explicitly releases it.
test_lane_floor_excludes_unmet_event_holds() {
  local home out
  home=$(make_home lane-floor-event-holds 3)
  add_kind_hold "$home" future-ext external --until 2099-01-01
  add_kind_hold "$home" future-parked parked --until 2099-01-01
  add_kind_hold "$home" future-future future --until 2099-01-01
  add_kind_hold "$home" past-ext external --until 2000-01-01
  add_load_hold "$home" cap-held
  add_lane "$home" live-1 working pane
  out=$(lane_floor_report "$home")
  case "$out" in
    *"backlog past-ext"*) fail "an expired external reminder must not grant dispatch permission: $out" ;;
  esac
  case "$out" in
    *"backlog cap-held"*) ;;
    *) fail "a load hold must still count as dispatchable, got: $out" ;;
  esac
  case "$out" in
    *future-ext*|*future-parked*|*future-future*) \
      fail "an external, parked, or future hold whose named event has not fired must never be counted as dispatchable: $out" ;;
  esac
  pass "lane floor: unmet external, parked, future, and expired-reminder holds stay excluded until release"
}

# The floor is the whole condition: identical work, enough lanes, no line.
test_lane_floor_silent_at_the_floor() {
  local home out
  home=$(make_home lane-floor-met 3)
  make_change "$home" proj alpha 2
  add_lane "$home" live-1 working pane
  printf '1\n' > "$home/config/lane-floor"
  out=$(lane_floor_report "$home")
  [ -z "$out" ] \
    || fail "a home at its floor must print nothing even with dispatchable work, got: $out"
  pass "lane floor: a home at its floor is silent with the same dispatchable work"
}

test_lane_floor_malformed_value_falls_back_to_default() {
  local home out
  home=$(make_home lane-floor-malformed 3)
  make_change "$home" proj alpha 1
  printf 'ten\n' > "$home/config/lane-floor"
  out=$(lane_floor_report "$home")
  case "$out" in
    *"floor=10"*) ;;
    *) fail "a non-numeric floor must read as unconfigured (10), never as zero, got: $out" ;;
  esac
  pass "lane floor: a malformed floor reads as the default, so a typo cannot disable enforcement"
}

# A Change a live worker is already implementing is not idle capacity.
test_lane_floor_excludes_a_change_a_live_brief_names() {
  local home out
  home=$(make_home lane-floor-brief 3)
  make_change "$home" proj alpha 2
  make_change "$home" proj beta 1
  add_lane "$home" live-1 working pane
  mkdir -p "$home/data/live-1"
  printf 'Complete the alpha Change under projects/proj.\n' > "$home/data/live-1/brief.md"
  out=$(lane_floor_report "$home")
  case "$out" in
    *"openspec proj:beta:1"*) ;;
    *) fail "an unclaimed Change must still be listed, got: $out" ;;
  esac
  case "$out" in
    *"proj:alpha"*) fail "a Change named by a live worker's instructions is not idle capacity: $out" ;;
  esac
  pass "lane floor: a Change a live worker's instructions name is excluded, an unclaimed sibling is not"
}

# A Change firstmate has already filed and held for the captain is not idle
# capacity either - the held record itself is what removes it, per the
# lane-floor skill's own contract.
test_lane_floor_excludes_a_change_a_captain_held_item_names() {
  local home out
  home=$(make_home lane-floor-captain-held 3)
  make_change "$home" proj alpha 2
  make_change "$home" proj beta 1
  add_change_hold "$home" alpha-held alpha captain
  add_lane "$home" live-1 working pane
  out=$(lane_floor_report "$home")
  case "$out" in
    *"openspec proj:beta:1"*) ;;
    *) fail "an unclaimed sibling Change must still be listed, got: $out" ;;
  esac
  case "$out" in
    *"proj:alpha"*) fail "a Change a captain-held item names must never be counted as idle capacity: $out" ;;
  esac
  pass "lane floor: a Change named by a captain-held item is excluded, an unclaimed sibling is not"
}

# Contract change: an expired date is a recheck reminder, not proof its named
# dependency fired. The Change stays excluded until the owner explicitly
# clears the hold, then returns to dispatchable capacity.
test_lane_floor_releases_a_past_dated_change_only_after_explicit_unhold() {
  local home out
  home=$(make_home lane-floor-past-hold 3)
  make_change "$home" proj alpha 1
  add_change_hold "$home" alpha-past alpha external --until 2000-01-01
  add_lane "$home" live-1 working pane
  out=$(lane_floor_report "$home")
  case "$out" in
    *"proj:alpha"*) fail "a past-dated hold must not release its named Change by itself: $out" ;;
  esac
  tasks-axi unhold alpha-past --file "$home/data/backlog.md" >/dev/null \
    || fail "the owning workflow could not explicitly release the Change hold"
  out=$(lane_floor_report "$home")
  case "$out" in
    *"openspec proj:alpha:1"*) ;;
    *) fail "an explicitly released Change must return to dispatchable capacity, got: $out" ;;
  esac
  pass "lane floor: a past-dated Change remains held until explicit release"
}

# A Change named by an item blocked on a still-open dependency is exactly as
# unactionable to firstmate as one held for the captain.
test_lane_floor_excludes_a_change_a_blocked_item_names() {
  local home out
  home=$(make_home lane-floor-blocked 3)
  make_change "$home" proj alpha 2
  make_change "$home" proj beta 1
  add_change_blocked "$home" alpha-blocked alpha alpha-blocker
  add_lane "$home" live-1 working pane
  out=$(lane_floor_report "$home")
  case "$out" in
    *"openspec proj:beta:1"*) ;;
    *) fail "an unclaimed sibling Change must still be listed, got: $out" ;;
  esac
  case "$out" in
    *"proj:alpha"*) fail "a Change a blocked item names must never be counted as idle capacity: $out" ;;
  esac
  pass "lane floor: a Change named by a blocked item is excluded, an unclaimed sibling is not"
}

# A Change named only past `tasks-axi list`'s own 500-char body-truncation cut
# must still be excluded: fm_lane_floor_held_text used to read the truncated
# listing text alone, so a Change named beyond the cut was silently reported
# as dispatchable capacity even though a captain-kind hold names it.
test_lane_floor_excludes_a_change_named_past_the_truncation_point() {
  local home out filler
  home=$(make_home lane-floor-truncated-body 3)
  make_change "$home" proj alpha 2
  make_change "$home" proj beta 1
  filler=$(printf 'x%.0s' $(seq 1 520))
  tasks-axi add alpha-long-body "long body, name held past the cut" --kind ship \
    --body "$filler the alpha Change is named only here, well past the 500-char body cut" \
    --file "$home/data/backlog.md" >/dev/null
  tasks-axi hold alpha-long-body --reason "waiting on a named event" --kind captain \
    --file "$home/data/backlog.md" >/dev/null
  add_lane "$home" live-1 working pane
  out=$(lane_floor_report "$home")
  case "$out" in
    *"openspec proj:beta:1"*) ;;
    *) fail "an unclaimed sibling Change must still be listed, got: $out" ;;
  esac
  case "$out" in
    *"proj:alpha"*) \
      fail "a Change named only past tasks-axi list's own truncation cut must never be counted as idle capacity: $out" ;;
  esac
  pass "lane floor: a Change named only past the body-truncation cut is still excluded"
}

# A Change name that is a strict prefix of a sibling Change's name must never
# be mismatched by the held-record match: the match is a whole slug token,
# never a substring.
test_lane_floor_does_not_mismatch_a_change_name_prefix() {
  local home out
  home=$(make_home lane-floor-prefix 3)
  make_change "$home" proj carry-assistant-runtime 1
  make_change "$home" proj carry-assistant-runtime-deferrals 1
  add_change_hold "$home" deferrals-held carry-assistant-runtime-deferrals captain
  add_lane "$home" live-1 working pane
  out=$(lane_floor_report "$home")
  case "$out" in
    *"openspec proj:carry-assistant-runtime:1"*) ;;
    *) fail "a Change whose name is only a prefix of the held one must still be listed, got: $out" ;;
  esac
  case "$out" in
    *"proj:carry-assistant-runtime-deferrals"*) \
      fail "the exact Change the held item names must never be counted: $out" ;;
  esac
  pass "lane floor: a held Change name is matched as a whole token, never as a prefix of a sibling"
}

test_lane_floor_excludes_archived_changes() {
  local home out
  home=$(make_home lane-floor-archive 3)
  make_change "$home" proj alpha 1
  mkdir -p "$home/projects/proj/openspec/changes/archive/old"
  printf -- '- [ ] 9.1 never dispatched again\n' \
    > "$home/projects/proj/openspec/changes/archive/old/tasks.md"
  out=$(lane_floor_report "$home")
  case "$out" in
    *"dispatchable=1"*) ;;
    *) fail "archived Changes must not be counted, got: $out" ;;
  esac
  case "$out" in
    *archive*|*old*) fail "an archived Change must never be listed: $out" ;;
  esac
  pass "lane floor: openspec/changes/archive is landed history and is never dispatchable"
}

# A lane declaring a bounded external wait is not a lane the floor can count.
test_lane_floor_does_not_count_a_paused_lane() {
  local home out
  home=$(make_home lane-floor-paused 3)
  make_change "$home" proj alpha 1
  add_lane "$home" live-1 working pane 'working: still going'
  add_lane "$home" live-2 paused status-log 'paused: waiting on an upstream release'
  out=$(lane_floor_report "$home")
  case "$out" in
    *"productive=1 "*) ;;
    *) fail "a lane whose newest event declares an external wait must not count as live, got: $out" ;;
  esac
  pass "lane floor: a paused lane is excluded from the live count"
}

# An unreadable backlog contributes no work rather than manufacturing a breach,
# and does not take the rest of the read down with it. Both halves are asserted
# against the same home: with the tool gone the ready item it holds vanishes
# from the count. The captain's step-5 hold contract intentionally changes the
# old expectation that an OpenSpec sibling remains dispatchable: when the same
# backlog's permission/hold data is unreadable, that sibling may itself be held
# by an unreadable row, so the whole forced-dispatch enumeration fails closed.
test_lane_floor_fails_soft_without_tasks_axi() {
  local home out
  home=$(make_home lane-floor-no-tool 3)
  add_ready "$home" would-be-dispatchable
  out=$(lane_floor_report_without_tasks_axi "$home")
  [ -z "$out" ] \
    || fail "a backlog that could not be read must never assert a breach, got: $out"
  make_change "$home" proj alpha 2
  out=$(lane_floor_report_without_tasks_axi "$home")
  [ -z "$out" ] \
    || fail "unknown backlog permission data must suppress forced dispatch, got: $out"
  case "$out" in
    *would-be-dispatchable*) fail "an unread backlog item must never be counted: $out" ;;
  esac
  pass "lane floor: unreadable hold permissions fail closed for backlog and OpenSpec dispatch"
}

# The cap is still the reason a dispatch cannot happen, but silence was the
# defect: a fleet of waiting holders at the cap suppressed the report entirely
# (captain 2026-09-08). The approved contract now reports the shortfall and
# names what could be released, and dispatch authority is unchanged - which is
# why the capacity-blocked line never tells the reader to dispatch.
test_lane_floor_at_the_concurrency_cap_reports_a_shortfall() {
  local home out
  home=$(make_home lane-floor-at-cap 3)
  make_change "$home" proj alpha 2
  add_lane "$home" live-1 working pane
  add_lane "$home" live-2 working pane
  printf '5\n' > "$home/config/lane-floor"
  out=$(lane_floor_report "$home")
  case "$out" in
    *"LANE FLOOR: productive=2 floor=5"*) ;;
    *) fail "under the cap the breach must still report, got: $out" ;;
  esac
  case "$out" in
    *capacity-blocked*) fail "under the cap this is an ordinary breach, got: $out" ;;
  esac
  printf '2\n' > "$home/config/concurrency-cap"
  out=$(lane_floor_report "$home")
  case "$out" in
    *"LANE FLOOR: productive=2 floor=5 dispatchable=1 capacity-blocked cap=2"*) ;;
    *) fail "a home at its cap must report the shortfall, never exit silently: $out" ;;
  esac
  case "$out" in
    *"dispatch before ending this turn"*) \
      fail "at the cap there is nothing to dispatch into, so the line must not ask for one: $out" ;;
  esac
  pass "lane floor: at the concurrency cap the shortfall is reported, not silently suppressed"
}

# A paused lane still holds its worktree slot, so it counts against the cap even
# though it is not productive: two lanes at a cap of two is capacity-blocked,
# which only holds if the paused one was counted.
test_lane_floor_cap_counts_a_paused_lane() {
  local home out
  home=$(make_home lane-floor-cap-paused 3)
  make_change "$home" proj alpha 2
  add_lane "$home" live-1 working pane
  add_lane "$home" live-2 paused status-log 'paused: waiting on an upstream release'
  printf '2\n' > "$home/config/concurrency-cap"
  out=$(lane_floor_report "$home")
  case "$out" in
    *"capacity-blocked cap=2"*) ;;
    *) fail "a paused lane still occupies its slot and must count against the cap, got: $out" ;;
  esac
  pass "lane floor: a paused lane is not productive but still holds its slot against the cap"
}

# The blind spot itself: a worker sitting quiet while its pipeline run drives CI
# is productive, and the newest status EVENT says otherwise. Counting the verb
# is what let a fleet of waiting holders read as a fleet of live lanes.
test_lane_floor_counts_productive_ci_behind_a_quiet_worker() {
  local home out
  home=$(make_home lane-floor-productive-ci 3)
  make_change "$home" proj alpha 2
  add_lane "$home" ci-lane working run-step 'paused: waiting on CI'
  out=$(lane_floor_report "$home")
  case "$out" in
    *"LANE FLOOR: productive=1 "*) ;;
    *) fail "a lane whose run is driving CI is productive, got: $out" ;;
  esac
  case "$out" in
    *"waiting=0"*) ;;
    *) fail "the stale paused EVENT must not be read as a declared wait, got: $out" ;;
  esac
  pass "lane floor: an active pipeline run behind a quiet worker counts as productive"
}

# An all-paused fleet at the cap is the exact fleet the captain watched go
# unreported: nothing is productive, nothing can be dispatched, and nothing can
# be released either - so the report must say all three rather than nothing.
test_lane_floor_all_paused_at_cap_reports_capacity_blocked() {
  local home out
  home=$(make_home lane-floor-all-paused 3)
  make_change "$home" proj alpha 2
  add_lane "$home" wait-1 paused status-log
  add_lane "$home" wait-2 paused status-log
  printf '2\n' > "$home/config/concurrency-cap"
  out=$(lane_floor_report "$home")
  case "$out" in
    *"LANE FLOOR: productive=0 floor=10 dispatchable=1 capacity-blocked cap=2"*) ;;
    *) fail "an all-paused fleet at the cap must report a capacity-blocked shortfall, got: $out" ;;
  esac
  case "$out" in
    *"waiting=2"*) ;;
    *) fail "the declared external waits must be reported separately, got: $out" ;;
  esac
  case "$out" in
    *"RELEASABLE: none"*) ;;
    *) fail "no releasable lane must be stated as an absence, never omitted, got: $out" ;;
  esac
  pass "lane floor: an all-paused fleet at the cap reports the shortfall and its empty release list"
}

# Dead and unreadable endpoints are the other half of the blind spot: an agent
# that exited with its worktree kept is neither productive nor silently live,
# and an endpoint whose state could not be read is its own bucket rather than
# being folded into either.
test_lane_floor_dead_and_unknown_endpoints_are_not_productive() {
  local home out
  home=$(make_home lane-floor-dead-unknown 3)
  make_change "$home" proj alpha 2
  add_lane "$home" gone-lane unknown none 'working: still going'
  add_lane "$home" murky-lane unknown pane
  add_lane "$home" busy-lane working pane
  printf 'project=%s\n' "$home" >> "$home/state/busy-lane.meta"
  out=$(lane_floor_report "$home")
  case "$out" in
    *"LANE FLOOR: productive=1 "*) ;;
    *) fail "only the reconciled working lane is productive, got: $out" ;;
  esac
  case "$out" in
    *"exited=1"*) ;;
    *) fail "an agent gone with its worktree kept must be reported, got: $out" ;;
  esac
  case "$out" in
    *"unknown=1"*) ;;
    *) fail "an unreadable endpoint must be its own bucket, got: $out" ;;
  esac
  case "$out" in
    *"SLOTS: lane-floor-dead-unknown=1/4"*) ;;
    *) fail "occupied worktree slots must be reported per project, got: $out" ;;
  esac
  pass "lane floor: dead and unknown endpoints are neither productive nor silently live"
}

# Contract correction: a parked pane still occupies capacity and its gate stays
# visible, but it is not productive work. The old expectation counted parked
# records as productive and could hide an entirely idle fleet.
test_lane_floor_reports_a_gated_parked_lane_without_counting_it_productive() {
  local home out
  home=$(make_home lane-floor-gated 3)
  make_change "$home" proj alpha 2
  add_lane "$home" gate-lane parked run-step
  out=$(lane_floor_report "$home")
  case "$out" in
    *"LANE FLOOR: productive=0 "*) ;;
    *) fail "a parked lane must not count as productive, got: $out" ;;
  esac
  case "$out" in
    *"gated=1"*) ;;
    *) fail "a gated lane must be visible as a gate, not hidden inside the count, got: $out" ;;
  esac
  pass "lane floor: a parked gated lane is visible without counting as productive"
}

# The other side of the same rule: a fleet whose every lane really is working is
# saturated, and saturation is silence.
test_lane_floor_silent_when_every_lane_is_productive() {
  local home out
  home=$(make_home lane-floor-saturated 3)
  make_change "$home" proj alpha 2
  add_lane "$home" busy-1 working pane
  add_lane "$home" busy-2 working run-step
  printf '2\n' > "$home/config/lane-floor"
  out=$(lane_floor_report "$home")
  [ -z "$out" ] \
    || fail "a fleet at its floor with every lane productive must be silent, got: $out"
  pass "lane floor: true saturation reports no breach"
}

# A finished lane holding a slot with nothing uncommitted in it is the one thing
# a capacity-blocked home can act on. Whether that work has LANDED is
# bin/fm-teardown.sh's test, never this report's, so the wording claims only
# what the working tree proves.
test_lane_floor_capacity_blocked_names_a_releasable_lane() {
  local home out repo dirty
  home=$(make_home lane-floor-releasable 3)
  make_change "$home" proj alpha 2
  repo="$home/clean-worktree"
  fm_git_init_commit "$repo"
  dirty="$home/dirty-worktree"
  fm_git_init_commit "$dirty"
  printf 'unlanded\n' > "$dirty/scratch.txt"
  add_lane "$home" finished-lane "done" run-step
  printf 'worktree=%s\n' "$repo" >> "$home/state/finished-lane.meta"
  add_lane "$home" dirty-lane "done" run-step
  printf 'worktree=%s\n' "$dirty" >> "$home/state/dirty-lane.meta"
  printf '2\n' > "$home/config/concurrency-cap"
  out=$(lane_floor_report "$home")
  case "$out" in
    *capacity-blocked*) ;;
    *) fail "two finished lanes at a cap of two is capacity-blocked, got: $out" ;;
  esac
  case "$out" in
    *"finished-lane"*) ;;
    *) fail "a finished lane with nothing uncommitted must be named releasable, got: $out" ;;
  esac
  case "$out" in
    *"dirty-lane"*) fail "a lane holding uncommitted work must never be named releasable: $out" ;;
  esac
  pass "lane floor: a capacity-blocked shortfall names the lanes that can be released"
}

# An unreadable reconciler is uncertainty, not evidence of work. The report
# must expose that uncertainty rather than silently promoting a status event to
# an active lane.
test_lane_floor_unreadable_reconciler_is_unknown_not_productive() {
  local home out
  home=$(make_home lane-floor-no-reconciler 3)
  make_change "$home" proj alpha 2
  : > "$home/state/live-1.meta"
  printf 'working: still going\n' > "$home/state/live-1.status"
  printf '1\n' > "$home/config/lane-floor"
  out=$(lane_floor_report "$home")
  case "$out" in
    *"LANE FLOOR: productive=0 "*"unknown=1"*"unreconciled=1"*) ;;
    *) fail "an unreadable reconciler must report unknown rather than fabricate activity: $out" ;;
  esac
  pass "lane floor: an unreadable reconciler is explicit unknown, never fabricated activity"
}

# Actual fm-crew-state output shapes remain disjoint: only verified current
# execution sources are active; a ready event, a gate, a deliberately parked
# lane, and an unreadable Codex pane are each visible in their own bucket.
test_lane_floor_actual_shaped_census_separates_active_prepared_gated_parked_and_unknown() {
  local home out
  home=$(make_home lane-floor-actual-shaped-census 3)
  make_change "$home" proj alpha 2
  add_lane "$home" active-run working run-step 'working: no-mistakes run is running'
  add_lane "$home" active-pane working pane 'working: implementation underway'
  add_lane "$home" prepared-lane working status-log 'working: prepared - candidate ready'
  add_lane "$home" gate-lane parked run-step 'needs-decision: review gate'
  add_lane "$home" inspection-lane needs-inspection run-step 'blocked: CI result needs inspection'
  add_lane "$home" parked-lane parked-exit task-record 'paused: agent deliberately stopped'
  add_lane "$home" codex-unknown unknown pane 'working: old status event only'
  add_lane "$home" status-only working status-log 'working: old status event only'
  out=$(lane_floor_report "$home")
  case "$out" in
    *"LANE FLOOR: productive=2 "*) ;;
    *) fail "only the run-step and pane lanes may count as active: $out" ;;
  esac
  case "$out" in
    *"LANES: total=8 active=2 prepared=1 gated=2 parked=1 waiting=0 exited=0 unknown=2"*) ;;
    *) fail "the actual-shaped census must keep each non-active condition distinct: $out" ;;
  esac
  pass "lane floor: actual-shaped census separates active, prepared, gated, parked, and unknown"
}

# The floor governs the fleet, not one home: a secondmate that inherits nothing
# would keep its own lanes idle under a floor the captain set once.
test_lane_floor_is_inherited_by_secondmate_homes() {
  # shellcheck source=bin/fm-config-inherit-lib.sh
  . "$ROOT/bin/fm-config-inherit-lib.sh"
  case " $FM_INHERITABLE_CONFIG " in
    *" lane-floor "*) ;;
    *) fail "config/lane-floor must be in FM_INHERITABLE_CONFIG so one floor governs the fleet" ;;
  esac
  pass "lane floor: the floor is inherited into secondmate homes with the rest of local config"
}

# --- lane floor at the wake drain -------------------------------------------
# The drain is where firstmate looks at the fleet, so the breach must reach it
# on EVERY drain - including the empty-queue path, where an idle home with a
# full queue is exactly the state that used to go unreported.

drain() {  # <home>
  FM_HOME="$1" PATH="$1/fakebin:$PATH" "$ROOT/bin/fm-wake-drain.sh" 2>&1
}

test_drain_prints_lane_floor_with_an_empty_queue() {
  local home out
  home=$(make_home drain-lane-floor 3)
  make_change "$home" proj alpha 2
  out=$(drain "$home") || fail "the drain failed on an empty queue: $out"
  case "$out" in
    *"LANE FLOOR: productive=0 floor=10 dispatchable=1"*) ;;
    *) fail "an empty-queue drain must still report the lane-floor breach, got: $out" ;;
  esac
  case "$out" in
    *"openspec proj:alpha:2"*) ;;
    *) fail "the drain must list the dispatchable work, got: $out" ;;
  esac
  pass "lane floor: the wake drain reports the breach even when the queue is empty"
}

# No once-per-tuple dedupe: an unchanged breach must nag on every drain, unlike
# the idle-capacity escalation beside it.
test_drain_repeats_the_lane_floor_while_it_holds() {
  local home first second
  home=$(make_home drain-lane-floor-repeat 3)
  make_change "$home" proj alpha 2
  first=$(drain "$home")
  second=$(drain "$home")
  case "$first" in *"LANE FLOOR:"*) ;; *) fail "the first drain must report, got: $first" ;; esac
  case "$second" in
    *"LANE FLOOR:"*) ;;
    *) fail "an unchanged breach must nag on every drain, not once: $second" ;;
  esac
  pass "lane floor: an unchanged breach is reported on every drain, never deduped away"
}

test_drain_silent_when_the_floor_is_met() {
  local home out
  home=$(make_home drain-lane-floor-met 3)
  make_change "$home" proj alpha 2
  printf '0\n' > "$home/config/lane-floor"
  out=$(drain "$home")
  case "$out" in
    *"LANE FLOOR"*) fail "a home at its floor must add nothing to the drain: $out" ;;
  esac
  pass "lane floor: the drain says nothing about a fleet that is already at its floor"
}

# --- lane floor at the turn end ---------------------------------------------

# The Stop-hook payload the guard reads, with the session id these cases key
# their block budget on.
guard_stop() {  # <home> <session-id> [--claude]
  local home=$1 session=$2; shift 2
  printf '{"stop_hook_active":false,"session_id":"%s"}' "$session" |
    PATH="$home/fakebin:$PATH" FM_HOME="$home" "$home/bin/fm-turnend-guard.sh" "$@" 2>&1
}

test_guard_blocks_a_turn_that_would_end_below_the_floor() {
  local home out rc
  home=$(make_home guard-lane-floor 3)
  install_guard_home "$home"
  make_change "$home" proj alpha 2
  set +e
  out=$(guard_stop "$home" lf-1 --claude)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || fail "an idle home with dispatchable work must block the turn (rc=$rc): $out"
  case "$out" in
    *"TURN WOULD END IDLE - LANES ARE BELOW THE FLOOR"*) ;;
    *) fail "the block must name the lane floor as the reason, got: $out" ;;
  esac
  case "$out" in
    *"●  LANE FLOOR: productive=0 floor=10 dispatchable=1"*) ;;
    *) fail "the block must carry the counted LANE FLOOR line in banner style, got: $out" ;;
  esac
  pass "lane floor: a Claude turn that would end below the floor is blocked"
}

# A capacity-blocked shortfall blocks too - releasing a lane, or telling the
# captain what is holding capacity, is an action this session can take - and it
# spends the same bounded budget, so a home whose capacity genuinely cannot be
# released is nagged three times and then allowed to end its turn. A cap of zero
# is the one shape that reaches this gate with no task in flight, which is what
# keeps the blind-fleet banner (which owns the in-flight case) out of the way.
test_guard_blocks_a_capacity_blocked_turn() {
  local home out rc i blocked=0 first=''
  home=$(make_home guard-lane-floor-cap 3)
  install_guard_home "$home"
  make_change "$home" proj alpha 2
  printf '0\n' > "$home/config/concurrency-cap"
  i=1
  while [ "$i" -le 4 ]; do
    set +e
    out=$(guard_stop "$home" lf-cap --claude)
    rc=$?
    set -e
    [ "$rc" -eq 2 ] && blocked=$((blocked + 1))
    [ "$i" -eq 1 ] && first=$out
    i=$((i + 1))
  done
  case "$first" in
    *"TURN WOULD END SHORT - LANES ARE BELOW THE FLOOR AND CAPACITY IS FULL"*) ;;
    *) fail "the block must name capacity as the blocker, not a missing dispatch: $first" ;;
  esac
  [ "$blocked" -eq 3 ] \
    || fail "a capacity-blocked turn must block within the budget and then allow, got $blocked: $out"
  pass "lane floor: a capacity-blocked turn end is blocked with its own reason, and stays bounded"
}

test_guard_lane_floor_is_claude_only() {
  local home out rc
  home=$(make_home guard-lane-floor-default 3)
  install_guard_home "$home"
  make_change "$home" proj alpha 2
  set +e
  out=$(guard_stop "$home" lf-2)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "the passive adapters must not be given a lane-floor block (rc=$rc): $out"
  case "$out" in
    *"LANES ARE BELOW THE FLOOR"*) fail "lane floor must not fire outside --claude: $out" ;;
  esac
  pass "lane floor: the turn-end block is Claude-only, because exit 2 means something else elsewhere"
}

# The fail-safe half: a check that cannot complete allows the stop.
test_guard_lane_floor_check_error_does_not_block() {
  local home out rc
  home=$(make_home guard-lane-floor-error 3)
  install_guard_home "$home"
  add_ready "$home" would-be-dispatchable
  set +e
  out=$(printf '{"stop_hook_active":false,"session_id":"lf-3"}' |
    PATH="$home/fakebin:/usr/bin:/bin" FM_HOME="$home" \
    "$home/bin/fm-turnend-guard.sh" --claude 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "a lane-floor check that could not read the backlog must allow the stop (rc=$rc): $out"
  case "$out" in
    *"LANES ARE BELOW THE FLOOR"*) fail "an unreadable backlog must never block a turn: $out" ;;
  esac
  pass "lane floor: a failed check allows the stop; only a positively read breach blocks"
}

# Unbounded blocking would wedge the session instead of enforcing anything.
test_guard_lane_floor_block_budget_is_bounded() {
  local home out rc i blocked=0
  home=$(make_home guard-lane-floor-budget 3)
  install_guard_home "$home"
  make_change "$home" proj alpha 2
  i=1
  while [ "$i" -le 4 ]; do
    set +e
    out=$(guard_stop "$home" lf-budget --claude)
    rc=$?
    set -e
    [ "$rc" -eq 2 ] && blocked=$((blocked + 1))
    i=$((i + 1))
  done
  [ "$blocked" -eq 3 ] \
    || fail "consecutive lane-floor blocks must stop at the budget of 3, got $blocked: $out"
  pass "lane floor: consecutive turn-end blocks are bounded, so a session is nagged and never wedged"
}

# A breach that clears must return the session's full budget, or a home that
# dispatched correctly and later fell back below the floor gets no enforcement.
test_guard_lane_floor_budget_resets_when_the_breach_clears() {
  local home out rc
  home=$(make_home guard-lane-floor-reset 3)
  install_guard_home "$home"
  make_change "$home" proj alpha 2
  set +e
  guard_stop "$home" lf-reset --claude >/dev/null
  guard_stop "$home" lf-reset --claude >/dev/null
  guard_stop "$home" lf-reset --claude >/dev/null
  set -e
  # The captain raises enough lanes to clear it, then the fleet drains again.
  printf '0\n' > "$home/config/lane-floor"
  set +e
  guard_stop "$home" lf-reset --claude >/dev/null
  set -e
  rm -f "$home/config/lane-floor"
  set +e
  out=$(guard_stop "$home" lf-reset --claude)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || fail "a cleared breach must return the full budget to the next one (rc=$rc): $out"
  pass "lane floor: clearing the breach resets the block budget for the next one"
}

# --- run --------------------------------------------------------------------

test_report_counts_and_disposition
test_report_frontier_empty
test_report_silent_when_nothing_applies
test_report_fails_soft_on_unreadable_pool
test_report_resolves_named_project_pool
test_report_one_unreadable_project_never_hides_a_readable_sibling
test_freeze_silences_line
test_freeze_recheck_date_never_auto_releases_captain_pause
test_freeze_supported_release_is_the_only_permission_transition
test_freeze_set_rejects_invalid_calendar_date
test_freeze_keeps_idle_capacity_false_but_arms_the_recheck
test_freeze_with_no_ready_work_needs_no_watcher
test_hold_stale_reported
test_hold_with_event_is_not_stale
test_hold_with_until_is_not_stale
test_hold_past_due_reported
test_expired_hold_becomes_dispatchable_only_after_explicit_unhold
test_unreadable_hold_metadata_fails_closed_for_capacity_and_dispatch_enumeration
test_hold_due_today_reported
test_fresh_hold_is_not_stale
test_capacity_held_load_kind_listed
test_capacity_held_silent_with_no_free_slots
test_capacity_held_reason_phrase_listed_under_other_kind
test_capacity_held_captain_kind_not_listed
test_capacity_held_escalates_once_per_unchanged_tuple
test_capacity_held_needs_supervision_with_zero_ready
test_predicate_true_on_idle_capacity
test_predicate_false_when_both_false
test_predicate_unchanged_when_work_in_flight
test_cap_default_is_thirteen
test_cap_at_configured_value_suppresses_the_line
test_cap_under_configured_value_still_reports
test_cap_malformed_file_falls_back_to_default
test_cap_zero_blocks_idle_capacity_with_no_in_flight_work
test_guard_banner_names_idle_capacity
test_guard_banner_names_idle_only_need
test_guard_silent_without_idle_capacity
test_guard_banner_names_capacity_held
test_teardown_prints_idle_capacity
test_teardown_prints_capacity_held
test_away_live_scan_buffers_idle_capacity
test_away_idle_scan_buffers_idle_capacity
test_away_scan_escalates_idle_capacity_once_per_unchanged_tuple
test_away_idle_scan_buffers_capacity_held
test_lane_floor_counts_non_captain_work_only
test_lane_floor_reports_prepared_waiters_and_live_validation_separately
test_research_first_allows_a_bounded_fair_comparison_for_an_unresolved_material_criterion
test_lane_floor_excludes_unmet_event_holds
test_lane_floor_silent_at_the_floor
test_lane_floor_malformed_value_falls_back_to_default
test_lane_floor_excludes_a_change_a_live_brief_names
test_lane_floor_excludes_a_change_a_captain_held_item_names
test_lane_floor_releases_a_past_dated_change_only_after_explicit_unhold
test_lane_floor_excludes_a_change_a_blocked_item_names
test_lane_floor_excludes_a_change_named_past_the_truncation_point
test_lane_floor_does_not_mismatch_a_change_name_prefix
test_lane_floor_excludes_archived_changes
test_lane_floor_does_not_count_a_paused_lane
test_lane_floor_fails_soft_without_tasks_axi
test_lane_floor_at_the_concurrency_cap_reports_a_shortfall
test_lane_floor_cap_counts_a_paused_lane
test_lane_floor_counts_productive_ci_behind_a_quiet_worker
test_lane_floor_all_paused_at_cap_reports_capacity_blocked
test_lane_floor_dead_and_unknown_endpoints_are_not_productive
test_lane_floor_reports_a_gated_parked_lane_without_counting_it_productive
test_lane_floor_silent_when_every_lane_is_productive
test_lane_floor_capacity_blocked_names_a_releasable_lane
test_lane_floor_unreadable_reconciler_is_unknown_not_productive
test_lane_floor_actual_shaped_census_separates_active_prepared_gated_parked_and_unknown
test_lane_floor_is_inherited_by_secondmate_homes
test_drain_prints_lane_floor_with_an_empty_queue
test_drain_repeats_the_lane_floor_while_it_holds
test_drain_silent_when_the_floor_is_met
test_guard_blocks_a_turn_that_would_end_below_the_floor
test_guard_blocks_a_capacity_blocked_turn
test_guard_lane_floor_is_claude_only
test_guard_lane_floor_check_error_does_not_block
test_guard_lane_floor_block_budget_is_bounded
test_guard_lane_floor_budget_resets_when_the_breach_clears
