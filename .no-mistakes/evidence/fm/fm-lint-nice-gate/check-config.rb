require 'yaml'
require 'json'
require 'open3'
require_relative '~/.no-mistakes/worktrees/049a88734b0e/01M63Y9BHCGGK3VKTPK8A3QH77/tests/ci-expression'

def check(value, message)
  raise message unless value
end
base = '9ff4e445eade0e08fe9e88501e2a575a4ad65041'
config = YAML.load_file('.no-mistakes.yaml')
commands = config.fetch('commands')
check(commands == {'lint' => ':'}, 'Expected only an explicit colon lint command and no commands.test')
stdout, stderr, status = Open3.capture3({'BASH_ENV' => nil, 'ENV' => nil}, 'bash', '--noprofile', '--norc', '-xec', commands.fetch('lint'))
check(status.success? && stdout.empty? && stderr == "+ :\n", 'Lint command did not execute as a successful shell builtin only')
workflow = YAML.load_file('.github/workflows/ci.yml')
base_bytes, git_status = Open3.capture2('git', 'show', "#{base}:.github/workflows/ci.yml")
check(git_status.success?, 'Could not read supplied baseline workflow')
check(workflow == YAML.safe_load(base_bytes), 'Hosted workflow semantics differ from supplied curated baseline')
events = workflow.fetch('on', workflow[true])
check(events.fetch('pull_request').fetch('branches').include?('curated'), 'Curated PRs do not trigger hosted workflow')
lint = workflow.fetch('jobs').fetch('lint')
check(lint.fetch('strategy').fetch('matrix').fetch('partition') == [1, 2, 3, 4], 'Expected all four hosted lint partitions')
check(!lint['continue-on-error'], 'Lint job ignores failures')
canonical = lint.fetch('steps').find { |step| step['name'] == 'Lint canonical partition' }
check(canonical && !canonical['continue-on-error'], 'Canonical lint step does not gate job success')
# The run field is the intentional public command contract in machine-consumed YAML.
argv = canonical.fetch('run').split("\n").drop(2).join("\n")
check(argv.start_with?('bin/fm-lint.sh --partition '), 'Hosted canonical lint executable has changed')
contexts = lint.fetch('strategy').fetch('matrix').fetch('partition').map { |partition| lint.fetch('name').gsub('${{ matrix.partition }}', partition.to_s) }
check(contexts == ['Lint 1', 'Lint 2', 'Lint 3', 'Lint 4'], 'Hosted check names differ from required contexts')
pi = workflow.fetch('jobs').fetch('tests-portable-parallel-1')
check(pi.fetch('name') == 'Behavior portable parallel 1', 'Pi lane has lost its required check name')
%w[0 1].each do |skip_push|
  context = {'github.event_name' => 'pull_request', 'vars.FM_CI_SKIP_PUSH' => skip_push}
  check(Expression.condition(lint['if'], context), 'Push opt-out disables PR lint')
  check(Expression.condition(pi['if'], context), 'Push opt-out disables required PR Pi lane')
end
lane, lane_status = Open3.capture2('bash', 'bin/fm-test-run.sh', '--list', '--lane', 'portable-parallel-1')
check(lane_status.success?, 'Lane consumer failed')
check(lane.lines.map(&:strip).include?('tests/fm-pi-primary-types.test.sh'), 'Required lane consumer omits Pi typecheck')
puts JSON.pretty_generate({
  oracle: 'Author-approved colon no-op and unchanged curated hosted CI coverage',
  commands: commands,
  shell: {exit: status.exitstatus, stdout: stdout, trace: stderr},
  workflow_semantics_unchanged_from: base,
  pull_request_target: 'curated',
  lint_contexts: contexts,
  lint_failures_propagate: true,
  pr_lint_and_pi_lane_enabled_with_push_opt_out: true,
  pi_typecheck: {check: pi.fetch('name'), selected_by_real_lane_consumer: true},
  load_under_20: 'Not measured; owed to the first no-mistakes run after landing because commands.lint is read from the default branch.'
})
