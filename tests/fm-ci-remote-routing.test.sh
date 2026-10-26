#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ruby - "$ROOT" <<'RUBY'
require 'yaml'
require 'open3'
require 'tmpdir'
require 'fileutils'
root=ARGV.fetch(0)
ci=YAML.load_file(File.join(root,'.github/workflows/ci.yml'))
checks=0
ci.fetch('jobs').each do |id,job|
 next if id=='macos-stock-bash'
 raise "#{id}: not on the standard hosted route" unless job.fetch('runs-on')=='ubuntu-latest'
 raise "#{id}: custom runner receipt remains" if job.fetch('steps').any?{|step| step['run'].to_s.include?('bin/fm-ci-evidence.py')}
 job.fetch('steps').each do |step|
  action=step['uses'].to_s
  if action.start_with?('actions/upload-artifact@')
   raise "#{id}: hosted copy still mandatory" unless step['continue-on-error']==true && step['if'].include?("vars.FM_CI_HOSTED_EVIDENCE == '1'")
  elsif action.start_with?('actions/download-artifact@')
   raise 'hosted download still mandatory' unless step['continue-on-error']==true && step['if'].include?("vars.FM_CI_HOSTED_EVIDENCE == '1'")
  elsif step['continue-on-error']
   raise "#{id}: actual gate made nonfatal"
  end
 end
 checks+=1
end
compliance=YAML.load_file(File.join(root,'.github/workflows/no-mistakes-required.yml'))
job=compliance.fetch('jobs').fetch('check')
raise 'separate compliance route changed' unless job['runs-on']=='ubuntu-latest'
action=job['steps'].find{|s| s['uses'].to_s.include?('require-no-mistakes@')}
raise 'genuine attestation gate changed' unless action['uses'].end_with?('@f6441c96c352a18b9cadcaef6b6c7017e9ac3970') && action['with']=={'exempt-authors'=>'kunchenguid'}
raise 'compliance made nonfatal' if job['continue-on-error'] || action['continue-on-error']
aggregate=ci.fetch('jobs').fetch('tests-timing-aggregate')
build=aggregate.fetch('steps').find{|step| step['name']=='Build aggregate timing summary'}
raise 'aggregate builder absent' unless build
Dir.mktmpdir('fm-ci-aggregate-') do |temp|
 runner_temp=File.join(temp,'runner-temp')
 timing=File.join(runner_temp,'fm-test-aggregate')
 FileUtils.mkdir_p([timing,File.join(temp,'bin')])
 stub=File.join(temp,'bin','fm-test-run.sh')
 File.write(stub,"#!/bin/sh\n[ \"\$1\" = --aggregate-json ] || exit 90\nout=\$2; shift 2\nprintf '%s\\n' \"\$@\" > \"\$RUNNER_TEMP/aggregate-inputs.txt\"\nprintf '{\"aggregate\":true}\\n' > \"\$out\"\n")
 File.chmod(0755,stub)
 expected=['fm-test-timing-portable-parallel-1.json','fm-test-timing-portable-parallel-2.json','fm-test-timing-herdr.json']
 expected+=ci.fetch('jobs').fetch('tests-portable-serial').fetch('strategy').fetch('matrix').fetch('shard').map{|shard| "fm-test-timing-portable-serial-#{shard}.json"}
 invoke=proc{Open3.capture2e({'RUNNER_TEMP'=>runner_temp},'/bin/bash','-c',build.fetch('run'),chdir:temp)}
 output,status=invoke.call
 raise 'no timing inputs produced a green aggregate' if status.success?
 raise 'missing-input failure was not named' unless expected.all?{|name| output.include?("::error::missing hosted timing input: #{name}")}
 File.write(File.join(timing,expected.first),'{}\n')
 output,status=invoke.call
 raise 'partial timing inputs produced a green aggregate' if status.success?
 raise 'missing lane was not named' unless output.include?("::error::missing hosted timing input: #{expected[1]}")
 expected.drop(1).each{|name| File.write(File.join(timing,name),'{}\n')}
 output,status=invoke.call
 raise "complete timing inputs failed: #{output}" unless status.success?
 recorded=File.readlines(File.join(runner_temp,'aggregate-inputs.txt'),chomp:true)
 raise 'aggregate omitted or added lane inputs' unless recorded==expected.map{|name| File.join(timing,name)}
 raise 'aggregate JSON was not produced' unless File.size?(File.join(runner_temp,'fm-test','fm-test-timing-aggregate.json'))
end
producers={
 'lint'=>['bin/fm-lint.sh --partition'],
 'test-coverage'=>['bin/fm-test-run.sh --check-coverage'],
 'tests-portable-parallel-1'=>['bin/fm-test-run.sh --lane portable-parallel-1', "--fail-on-gate-skip 'Pi extension typecheck prerequisite not found'"],
 'tests-portable-parallel-2'=>['bin/fm-test-run.sh --lane portable-parallel-2'],
 'tests-portable-serial'=>['bin/fm-test-run.sh --lane "$FM_SERIAL_LANE"', "--fail-on-gate-skip 'Pi extension typecheck prerequisite not found'"],
 'tests-herdr'=>['bin/fm-test-run.sh --family real-herdr-gated', "--fail-on-gate-skip 'herdr not found'", 'bin/fm-herdr-ci-cleanup.sh teardown'],
 'invariants'=>['CLAUDE.md must be the canonical @AGENTS.md pointer'],
}
producers.each do |id,commands|
 runs=ci.fetch('jobs').fetch(id).fetch('steps').map{|step| step['run'].to_s}.join("\n")
 commands.each{|command| raise "#{id}: required producer or guard removed: #{command}" unless runs.include?(command)}
end
raise 'required job expansion changed' unless ci.fetch('jobs').reject{|id,_| id=='tests-timing-aggregate'}.sum{|_,job| (job.dig('strategy','matrix') || {}).values.map(&:length).inject(1,:*)}==17
puts "ok - #{checks} Linux jobs use hosted routing; all 17 required jobs retain their producers and gates, separate compliance stays intact, optional aggregate refuses missing inputs"
RUBY
