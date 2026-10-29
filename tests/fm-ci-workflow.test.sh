#!/usr/bin/env bash
# Contract tests for .github/workflows/ci.yml's runner-spend safeguards.
#
# Origin: the 2026-09-12 GitHub Actions starvation incident. firstmate CI had no
# concurrency deduplication, so every superseded PR head kept its full job
# fan-out, and four jobs carried no timeout at all. These tests hold both
# safeguards: PR runs supersede within one PR while main pushes are never
# cancelled, and every CI job carries a finite hang tripwire drawn from the
# three-tier timeout policy that docs/fm-test-portable-shards.md "Timeouts"
# owns (fast, normal, heavy) plus the named serial exception, so no job drifts back to a one-off number.
#
# They also hold the fork controls: FM_CI_SKIP_PUSH skips the push run,
# FM_CI_SKIP_MACOS skips macOS, and FM_CI_HOSTED_EVIDENCE enables the aggregate
# only when its hosted timing inputs can exist.
#
# The workflow is parsed as YAML and its concurrency and job-level `if`
# expressions are resolved against simulated pull_request and push contexts,
# so the assertions describe what GitHub would do, not how the file happens
# to be spelled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"

assert_present "$CI_WORKFLOW" ".github/workflows/ci.yml is missing"
command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/ci.yml as YAML"

# Evaluate the subset of GitHub's expression language that ci.yml uses -
# string literals, context lookups, the status functions, !, ==, !=, &&,
# ||, and parentheses - against a simulated context hash, following the
# documented operator precedence, the case-insensitive string comparison, and
# the `a || b` fallback that returns the first truthy operand rather than a
# boolean. The status functions read the simulated outcome of the needed jobs
# from the context key "needs.status" (success, failure, or cancelled), which
# defaults to success.

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>".
resolve_concurrency() {
  local event=$1 pr_number=$2 run_id=$3
  ruby -ryaml -r"$ROOT/tests/ci-expression.rb" -e '
doc = YAML.load_file(ARGV[0])
concurrency = doc.fetch("concurrency")
context = {
  "github.workflow" => doc.fetch("name"),
  "github.event_name" => ARGV[1],
  "github.event.pull_request.number" => ARGV[2],
  "github.run_id" => ARGV[3],
}

interpolate = lambda do |raw|
  raw.to_s.gsub(/\$\{\{(.+?)\}\}/) { Expression.evaluate(Regexp.last_match(1), context).to_s }
end

puts [interpolate.call(concurrency.fetch("group")),
      interpolate.call(concurrency.fetch("cancel-in-progress"))].join("\t")
' "$CI_WORKFLOW" "$event" "$pr_number" "$run_id"
}

# Print, one per line in workflow order, the jobs whose job-level `if`
# resolves true under one simulated event and fork variable setting; an unset
# repository variable reads as the empty string, as GitHub documents.
jobs_running_under() {  # <event> <FM_CI_SKIP_PUSH> <FM_CI_SKIP_MACOS> <FM_CI_HOSTED_EVIDENCE>
  ruby -ryaml -r"$ROOT/tests/ci-expression.rb" -e '
context = {
  "github.event_name" => ARGV[1],
  "vars.FM_CI_SKIP_PUSH" => ARGV[2],
  "vars.FM_CI_SKIP_MACOS" => ARGV[3],
  "vars.FM_CI_HOSTED_EVIDENCE" => ARGV[4],
}
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  puts name if Expression.condition(job["if"], context)
end
' "$CI_WORKFLOW" "$1" "$2" "$3" "$4"
}

job_timeout() {
  ruby -ryaml -e '
puts YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" "$1"
}

# Tier membership is the executable inventory of the timeout policy: a new job
# must join a tier, and a job-level value outside these tiers is exactly the
# one-off number the policy removed.
FAST_TIER_JOBS='test-coverage invariants tests-timing-aggregate'
NORMAL_TIER_JOBS='lint tests-portable-parallel-1 tests-portable-parallel-2 macos-stock-bash'
SERIAL_EXCEPTION_JOBS='tests-portable-serial'
HEAVY_TIER_JOBS='tests-herdr'

# Print the one timeout every listed job shares; fail on any disagreement.
tier_timeout() {  # <tier> <job>...
  local tier=$1 job first actual
  shift
  first=
  for job in "$@"; do
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    case "$actual" in ''|*[!0-9]*) fail "$job ($tier tier) has no integer timeout, got $actual" ;; esac
    if [ -z "$first" ]; then
      first=$actual
    elif [ "$actual" != "$first" ]; then
      fail "$tier tier jobs must share one timeout, got $first and $actual ($job)"
    fi
  done
  printf '%s\n' "$first"
}

# Print every job id in the workflow, one per line.
workflow_jobs() {
  ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("jobs").keys' "$CI_WORKFLOW"
}

group_of() { printf '%s\n' "$1" | cut -f1; }
cancel_of() { printf '%s\n' "$1" | cut -f2; }

test_pr_pushes_supersede_within_one_pr() {
  local first second
  first=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  second=$(resolve_concurrency pull_request 108 900002) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "two runs of one PR must share a concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "PR runs must cancel the in-progress run, got $(cancel_of "$first")"
  pass "a newer push to one PR supersedes that PR's in-flight CI"
}

test_separate_prs_do_not_cancel_each_other() {
  local one two
  one=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  two=$(resolve_concurrency pull_request 109 900003) || fail "could not resolve PR concurrency"
  [ "$(group_of "$one")" != "$(group_of "$two")" ] \
    || fail "distinct PRs must not share a concurrency group ($(group_of "$one"))"
  pass "distinct PRs get distinct concurrency groups"
}

test_main_pushes_are_never_cancelled() {
  local first second
  first=$(resolve_concurrency push '' 900010) || fail "could not resolve push concurrency"
  second=$(resolve_concurrency push '' 900011) || fail "could not resolve push concurrency"
  [ "$(group_of "$first")" != "$(group_of "$second")" ] \
    || fail "each main push must get its own concurrency group, got $(group_of "$first") twice"
  [ "$(cancel_of "$first")" = false ] \
    || fail "push runs must never cancel an in-progress run, got $(cancel_of "$first")"
  pass "every main push keeps its own group and is never cancelled"
}

test_every_job_has_a_finite_timeout() {
  local reported
  reported=$(ruby -ryaml -e '
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  timeout = job["timeout-minutes"]
  next if timeout.is_a?(Integer) && timeout > 0
  puts "#{name}: #{timeout.inspect}"
end
' "$CI_WORKFLOW") || fail "could not read job timeouts from ci.yml"
  [ -z "$reported" ] || fail "these CI jobs have no finite hang tripwire:"$'\n'"$reported"
  pass "every ci.yml job carries a finite timeout"
}

# Every job sits in exactly one tier, and the workflow carries exactly four
# distinct job-level timeouts: one per tier plus the named serial exception.
test_every_job_belongs_to_exactly_one_timeout_tier() {
  local expected actual distinct
  # shellcheck disable=SC2086
  expected=$(printf '%s\n' $FAST_TIER_JOBS $NORMAL_TIER_JOBS $SERIAL_EXCEPTION_JOBS $HEAVY_TIER_JOBS | LC_ALL=C sort)
  [ "$(printf '%s\n' "$expected" | LC_ALL=C sort -u)" = "$expected" ] \
    || fail "a job is listed in more than one timeout tier:"$'\n'"$expected"
  actual=$(workflow_jobs | LC_ALL=C sort) || fail "could not list ci.yml jobs"
  [ "$actual" = "$expected" ] \
    || fail "ci.yml jobs and the timeout tiers disagree; every job must join one tier"$'\n'"workflow: $(printf '%s' "$actual" | tr '\n' ' ')"$'\n'"tiers: $(printf '%s' "$expected" | tr '\n' ' ')"
  distinct=$(for job in $expected; do job_timeout "$job"; done | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$distinct" = 4 ] \
    || fail "ci.yml must carry exactly four distinct job timeouts (fast, normal, serial exception, heavy), got $distinct"
  pass "every ci.yml job belongs to one of the timeout tiers"
}

# Fast tier: seconds-long checks share one short tripwire in the 5-10 minute band.
test_fast_tier_shares_one_short_tripwire() {
  local fast
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  [ "$fast" -ge 5 ] && [ "$fast" -le 10 ] \
    || fail "fast tier must be a 5-10 minute hang tripwire, got $fast"
  pass "fast tier jobs share one $fast minute tripwire"
}

# Normal tier: every test or lint lane shares ONE fixed 30-minute budget,
# above the fast tier. That budget is a hang tripwire, not a packing estimate.
test_normal_tier_shares_one_budget() {
  local fast normal
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  [ "$normal" -gt "$fast" ] \
    || fail "normal tier ($normal) must exceed the fast tier ($fast)"
  [ "$normal" = 30 ] \
    || fail "normal tier must be the single 30-minute shared budget, got $normal"
  pass "normal tier jobs share one $normal minute budget"
}

# Serial exception: the portable serial shards alone carry a 45-minute hang
# tripwire, because the slowest shard needs about 29 minutes by construction.
test_serial_exception_is_45_minutes() {
  local serial
  # shellcheck disable=SC2086
  serial=$(tier_timeout serial $SERIAL_EXCEPTION_JOBS) || exit 1
  [ "$serial" = 45 ] \
    || fail "the portable serial job must be the 45-minute exception, got $serial"
  pass "portable serial jobs carry the $serial minute exception"
}

# Heavy tier: Herdr alone carries a job-level last-resort backstop above the
# normal tier, while its family-run step owns a tighter tripwire so the
# always() cleanup and timing upload still run after a hang.
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop() {
  local normal heavy step
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  heavy=$(tier_timeout heavy $HEAVY_TIER_JOBS) || exit 1
  [ "$heavy" -gt "$normal" ] \
    || fail "heavy tier backstop ($heavy) must exceed the normal tier ($normal)"
  [ "$heavy" -ge 60 ] && [ "$heavy" -le 75 ] \
    || fail "heavy tier backstop must stay a 60-75 minute last resort, got $heavy"
  step=$(ruby -ryaml -r"$ROOT/tests/ci-expression.rb" -e '
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("steps")
index = steps.index { |s| s["id"] == "run-real-herdr-family" }
raise "no run-real-herdr-family step" unless index
teardown = steps.index { |s| s["id"] == "cleanup-herdr-lab-sessions" }
raise "no cleanup-herdr-lab-sessions step" unless teardown
raise "teardown must follow the family-run step" unless teardown > index
%w[success failure cancelled].each do |status|
  raise "teardown must run after #{status}" unless Expression.condition(steps[teardown]["if"], {"needs.status" => status})
end
puts steps[index].fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" tests-herdr) || fail "could not read the Herdr family-run step"
  case "$step" in ''|*[!0-9]*) fail "the Herdr family-run step needs its own timeout-minutes, got $step" ;; esac
  [ "$step" = 20 ] \
    || fail "the Herdr family-run step must be the 20-minute tripwire, got $step"
  [ "$step" -lt "$heavy" ] \
    || fail "the Herdr step tripwire ($step) must stay below the job backstop ($heavy)"
  pass "Herdr keeps a $step minute step tripwire under a $heavy minute job backstop"
}

# A "-" in the table means the variable is unset.
test_fork_skip_variables_are_opt_in() {
  local all event skip_push skip_macos hosted expected want actual
  all=$(workflow_jobs) || fail "could not list ci.yml jobs"
  printf '%s\n' "$all" | grep -qx macos-stock-bash \
    || fail "the macOS job is missing from ci.yml, so the table below would prove nothing"
  while read -r event skip_push skip_macos hosted expected; do
    [ "$skip_push" != - ] || skip_push=
    [ "$skip_macos" != - ] || skip_macos=
    [ "$hosted" != - ] || hosted=
    case $expected in
      all) want=$all ;;
      none) want= ;;
      all-but-macos) want=$(printf '%s\n' "$all" | grep -vx macos-stock-bash) ;;
      all-but-aggregate) want=$(printf '%s\n' "$all" | grep -vx tests-timing-aggregate) ;;
      all-but-macos-aggregate) want=$(printf '%s\n' "$all" | grep -Evx 'macos-stock-bash|tests-timing-aggregate') ;;
      *) fail "unknown expectation $expected" ;;
    esac
    actual=$(jobs_running_under "$event" "$skip_push" "$skip_macos" "$hosted") \
      || fail "could not resolve the job conditions for $event FM_CI_SKIP_PUSH=$skip_push FM_CI_SKIP_MACOS=$skip_macos FM_CI_HOSTED_EVIDENCE=$hosted"
    [ "$actual" = "$want" ] \
      || fail "$event with FM_CI_SKIP_PUSH=$skip_push FM_CI_SKIP_MACOS=$skip_macos must run $expected jobs"$'\n'"ran: $(printf '%s' "$actual" | tr '\n' ' ')"$'\n'"wanted: $(printf '%s' "$want" | tr '\n' ' ')"
  done <<'TABLE'
push         - - - all-but-aggregate
pull_request - - - all-but-aggregate
push         1 - - none
pull_request 1 - - all-but-aggregate
pull_request - 1 - all-but-macos-aggregate
push         - 1 - all-but-macos-aggregate
pull_request - - 1 all
push         - 1 1 all-but-macos
TABLE
  pass "push, macOS and hosted-evidence variables change only their own jobs"
}

# Print true or false: whether one job's job-level `if` resolves true under
# one simulated event, fork variable setting, and outcome of its needed jobs.
job_runs_under() {  # <job> <event> <FM_CI_SKIP_PUSH> <FM_CI_SKIP_MACOS> <FM_CI_HOSTED_EVIDENCE> <needs status>
  ruby -ryaml -r"$ROOT/tests/ci-expression.rb" -e '
context = {
  "github.event_name" => ARGV[2],
  "vars.FM_CI_SKIP_PUSH" => ARGV[3],
  "vars.FM_CI_SKIP_MACOS" => ARGV[4],
  "vars.FM_CI_HOSTED_EVIDENCE" => ARGV[5],
  "needs.status" => ARGV[6],
}
puts Expression.condition(YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1])["if"], context)
' "$CI_WORKFLOW" "$@"
}

# The aggregate runs after a failed lane only when hosted timing inputs exist.
test_timing_aggregate_still_runs_after_a_failed_lane() {
  local event skip_push hosted expected actual
  while read -r event skip_push hosted expected; do
    [ "$skip_push" != - ] || skip_push=
    [ "$hosted" != - ] || hosted=
    actual=$(job_runs_under tests-timing-aggregate "$event" "$skip_push" '' "$hosted" failure) \
      || fail "could not resolve the aggregate condition for $event FM_CI_SKIP_PUSH=$skip_push"
    [ "$actual" = "$expected" ] \
      || fail "after a failed lane, the aggregate on $event with FM_CI_SKIP_PUSH=$skip_push must resolve $expected, got $actual"
  done <<'TABLE'
pull_request - - false
push         - - false
pull_request - 1 true
push         - 1 true
push         1 1 false
TABLE
  pass "the timing aggregate skips without hosted inputs and still runs after a failed lane when enabled"
}

test_ci_matrices_match_executable_partitions() {
  ruby -ryaml -ropen3 - "$CI_WORKFLOW" "$ROOT" <<'RUBY' || fail "CI partition contract"
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
root = ARGV[1]
serial = jobs.fetch("tests-portable-serial").fetch("strategy")
raise "serial failures must not cancel other shards" unless serial.fetch("fail-fast") == false
matrix = serial.fetch("matrix")
raise "unexpected serial dimensions" unless matrix.keys == ["shard"]
shards = matrix.fetch("shard")
lanes, status = Open3.capture2(File.join(root, "bin/fm-test-run.sh"), "--list-lanes")
raise "cannot list runner lanes" unless status.success?
actual = lanes.lines.map(&:strip).select { |l| l.match?(/\Aportable-serial-\d+of\d+\z/) }
expected = shards.map { |s| "portable-serial-#{s}of#{shards.length}" }
raise "CI matrix and runner disagree" unless actual.sort == expected.sort
lint = jobs.fetch("lint").fetch("strategy")
raise "lint failures must not cancel another partition" unless lint.fetch("fail-fast") == false
matrix = lint.fetch("matrix")
raise "unexpected lint dimensions" unless matrix.keys == ["partition"]
parts = matrix.fetch("partition")
roots = parts.flat_map do |p|
  output, result = Open3.capture2(File.join(root, "bin/fm-lint.sh"), "--partition", "#{p}of#{parts.length}", "--list-files")
  raise "unsupported lint partition" unless result.success?
  output.lines.map(&:strip)
end
canonical, result = Open3.capture2({"CI" => "true"}, File.join(root, "bin/fm-lint.sh"), "--list-files")
raise "lint matrix loses or duplicates canonical roots" unless result.success? && roots.sort == canonical.lines.map(&:strip).sort
RUBY
  pass "CI matrices cover every executable serial lane and canonical lint root exactly once"
}

test_ci_matrices_match_executable_partitions
test_pr_pushes_supersede_within_one_pr
test_separate_prs_do_not_cancel_each_other
test_main_pushes_are_never_cancelled
test_fork_skip_variables_are_opt_in
test_timing_aggregate_still_runs_after_a_failed_lane
test_every_job_has_a_finite_timeout
test_every_job_belongs_to_exactly_one_timeout_tier
test_fast_tier_shares_one_short_tripwire
test_normal_tier_shares_one_budget
test_serial_exception_is_45_minutes
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop
