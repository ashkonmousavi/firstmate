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
 labels=Array(job.fetch('runs-on')).map{|x| x.to_s.gsub(/\A\$\{\{\s*'([^']+)'\s*\}\}\z/,'\\1').downcase}
 raise "#{id}: not the owned remote-only route" unless labels.sort==%w[self-hosted linux x64 fm-fork-remote].sort
 job.fetch('steps').each_with_index do |step,index|
  action=step['uses'].to_s
  if action.start_with?('actions/upload-artifact@')
   raise "#{id}: upload lacks persistent predecessor" unless job['steps'][0...index].any?{|s| s['run'].to_s.include?('bin/fm-ci-evidence.py') && s['if']=='always()' && !s['continue-on-error']}
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
raise 'compliance is not on the remote route' unless job['runs-on']==ci['jobs']['lint']['runs-on']
action=job['steps'].find{|s| s['uses'].to_s.include?('require-no-mistakes@')}
raise 'genuine attestation gate changed' unless action['uses'].end_with?('@f6441c96c352a18b9cadcaef6b6c7017e9ac3970') && action['with']=={'exempt-authors'=>'kunchenguid'}
raise 'compliance made nonfatal' if job['continue-on-error'] || action['continue-on-error']
aggregate=ci.fetch('jobs').fetch('tests-timing-aggregate')
build=aggregate.fetch('steps').find{|step| step['name']=='Build aggregate timing summary'}
receipt=aggregate.fetch('steps').find{|step| step['name']=='Preserve aggregate evidence on the owned runner'}
raise 'aggregate steps absent' unless build && receipt
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
raise 'aggregate receipt does not require its JSON' unless receipt.fetch('run').include?('--require "$RUNNER_TEMP/fm-test/fm-test-timing-aggregate.json"')
puts "ok - #{checks} Linux jobs and genuine compliance use remote-only routing; empty/partial aggregate inputs fail, complete inputs aggregate, and receipt requires JSON"
RUBY
