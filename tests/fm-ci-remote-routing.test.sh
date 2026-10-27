#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ruby -r"$ROOT/tests/ci-expression.rb" - "$ROOT" <<'RUBY'
require 'yaml'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
root=ARGV.fetch(0)
ci=YAML.load_file(File.join(root,'.github/workflows/ci.yml'))
checks=0
ci.fetch('jobs').each do |id,job|
 next if id=='macos-stock-bash'
 raise "#{id}: not on the standard hosted route" unless job.fetch('runs-on')=='ubuntu-24.04'
 raise "#{id}: actual job made nonfatal" if job['continue-on-error']
 job.fetch('steps').each do |step|
  action=step['uses'].to_s
  upload=action.start_with?('actions/upload-artifact@')
  download=action.start_with?('actions/download-artifact@')
  if upload || download
   raise "#{id}: hosted copy still mandatory" unless step['continue-on-error']==true
   ['', '0', '1'].product(%w[success failure cancelled]).each do |hosted,status|
    context={'vars.FM_CI_HOSTED_EVIDENCE'=>hosted,'needs.status'=>status}
    expected=hosted=='1' && (upload || status=='success')
    raise "#{id}: hosted copy condition is wrong for #{context}" unless Expression.condition(step['if'],context)==expected
   end
  elsif step['continue-on-error']
   raise "#{id}: actual gate made nonfatal"
  end
 end
 checks+=1
end
compliance=YAML.load_file(File.join(root,'.github/workflows/no-mistakes-required.yml'))
job=compliance.fetch('jobs').fetch('check')
raise 'separate compliance route changed' unless job['runs-on']=='ubuntu-24.04'
action=job['steps'].find{|s| s['name']=='Verify no-mistakes signature and pipeline attestation'}
raise 'genuine attestation gate changed' unless action && action['uses']=='kunchenguid/no-mistakes/.github/actions/require-no-mistakes@f6441c96c352a18b9cadcaef6b6c7017e9ac3970' && action['with']=={'exempt-authors'=>'kunchenguid'}
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
 expected=['fm-test-timing-portable-parallel-1.json','fm-test-timing-portable-parallel-2.json','fm-test/fm-test-timing-herdr.json']
 expected+=ci.fetch('jobs').fetch('tests-portable-serial').fetch('strategy').fetch('matrix').fetch('shard').map{|shard| "fm-test-timing-portable-serial-#{shard}.json"}
 upload=ci.fetch('jobs').fetch('tests-herdr').fetch('steps').find{|step| step['uses'].to_s.start_with?('actions/upload-artifact@')}
 paths=upload.fetch('with').fetch('path').lines.map{|line| line.strip.sub('${{ runner.temp }}',runner_temp)}
 ancestors=paths.map{|path| File.dirname(path).split('/')}
 common=ancestors.shift
 ancestors.each{|parts| common=common.zip(parts).take_while{|a,b| a==b}.map(&:first)}
 archive_root=common.join('/')+'/'
 archived=paths.map{|path| path.delete_prefix(archive_root)}
 raise 'Herdr archive no longer contains nested timing and diagnostics' unless archived.sort==['fm-test/fm-test-timing-herdr.json','fm-herdr/sessions-before.json','fm-herdr/default-server.log'].sort
 invoke=proc{Open3.capture2e({'RUNNER_TEMP'=>runner_temp},'/bin/bash','-c',build.fetch('run'),chdir:temp)}
 output,status=invoke.call
 raise 'no timing inputs produced a green aggregate' if status.success?
 raise 'missing-input failure was not named' unless expected.all?{|name| output.include?("::error::missing hosted timing input: #{File.basename(name)}")}
 File.write(File.join(timing,expected.first),"{}\n")
 output,status=invoke.call
 raise 'partial timing inputs produced a green aggregate' if status.success?
 raise 'missing lane was not named' unless output.include?("::error::missing hosted timing input: #{expected[1]}")
 expected.drop(1).each do |name|
  path=File.join(timing,name)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path,"{}\n")
 end
 output,status=invoke.call
 raise "complete timing inputs failed: #{output}" unless status.success?
 recorded=File.readlines(File.join(runner_temp,'aggregate-inputs.txt'),chomp:true)
 raise 'aggregate omitted or added lane inputs' unless recorded==expected.map{|name| File.join(timing,name)}
 raise 'aggregate JSON was not produced' unless File.size?(File.join(runner_temp,'fm-test','fm-test-timing-aggregate.json'))
end
Dir.mktmpdir('fm-ci-producers-') do |temp|
 runner_temp=File.join(temp,'runner-temp')
 FileUtils.mkdir_p([runner_temp,File.join(temp,'bin')])
 log=File.join(temp,'producer.json')
 %w[fm-test-run.sh fm-lint.sh fm-herdr-ci-cleanup.sh].each do |command|
  path=File.join(temp,'bin',command)
  File.write(path,"#!/usr/bin/env ruby\nrequire 'json'\nFile.write(ENV.fetch('PRODUCER_LOG'),JSON.dump([File.basename($0),ARGV]))\nexit Integer(ENV.fetch('PRODUCER_EXIT'))\n")
  File.chmod(0755,path)
 end
 run=proc do |id,name,command,args,context={},environment={}|
  step=ci.fetch('jobs').fetch(id).fetch('steps').find{|item| item['name']==name || item['id']==name}
  raise "#{id}: producer step missing: #{name}" unless step
  script=step.fetch('run').gsub(/\$\{\{(.+?)\}\}/){Expression.evaluate(Regexp.last_match(1),context).to_s}
  env={'RUNNER_TEMP'=>runner_temp,'PRODUCER_LOG'=>log}.merge(environment)
  [0,37].each do |code|
   FileUtils.rm_f(log)
   output,status=Open3.capture2e(env.merge('PRODUCER_EXIT'=>code.to_s),'/bin/bash','-c',script,chdir:temp)
   raise "#{id}: producer was not invoked: #{output}" unless File.file?(log)
   raise "#{id}: producer arguments changed" unless JSON.parse(File.read(log))==[command,args]
   raise "#{id}: producer outcome #{code} was lost: #{output}" unless status.success? == (code==0)
  end
 end
 ci.fetch('jobs').fetch('lint').fetch('strategy').fetch('matrix').fetch('partition').each do |partition|
  run.call('lint','Lint canonical partition','fm-lint.sh',
           ['--partition',"#{partition}of2",'--telemetry',"#{runner_temp}/fm-lint/partition-#{partition}.tsv"],
           {'matrix.partition'=>partition,'strategy.job-total'=>2})
 end
 run.call('test-coverage','Prove complete regression partition','fm-test-run.sh',['--check-coverage'])
 [1,2].each do |shard|
  args=['--lane',"portable-parallel-#{shard}"]
  args+=['--fail-on-gate-skip','Pi extension typecheck prerequisite not found'] if shard==1
  args+=['--json',"#{runner_temp}/fm-test/fm-test-timing-portable-parallel-#{shard}.json"]
  run.call("tests-portable-parallel-#{shard}","Run portable parallel shard #{shard}",'fm-test-run.sh',args)
 end
 ci.fetch('jobs').fetch('tests-portable-serial').fetch('strategy').fetch('matrix').fetch('shard').each do |shard|
  step=ci.fetch('jobs').fetch('tests-portable-serial').fetch('steps').find{|item| item['env'] && item['env'].key?('FM_SERIAL_LANE')}
  context={'matrix.shard'=>shard,'strategy.job-total'=>9}
  environment=step.fetch('env').transform_values{|value| value.to_s.gsub(/\$\{\{(.+?)\}\}/){Expression.evaluate(Regexp.last_match(1),context).to_s}}
  run.call('tests-portable-serial',step.fetch('name'),'fm-test-run.sh',
           ['--lane',"portable-serial-#{shard}of9",'--fail-on-gate-skip','Pi extension typecheck prerequisite not found',
            '--json',"#{runner_temp}/fm-test/fm-test-timing-portable-serial-#{shard}.json"],context,environment)
 end
 run.call('tests-herdr','run-real-herdr-family','fm-test-run.sh',
          ['--family','real-herdr-gated','--fail-on-gate-skip','herdr not found','--json',"#{runner_temp}/fm-test/fm-test-timing-herdr.json"])
 run.call('tests-herdr','cleanup-herdr-lab-sessions','fm-herdr-ci-cleanup.sh',['teardown',"#{runner_temp}/fm-herdr/sessions-before.json"])
 FileUtils.mkdir_p(File.join(temp,'.claude'))
 File.symlink('../.agents/skills',File.join(temp,'.claude/skills'))
 pointer=File.join(temp,'CLAUDE.md')
 File.write(pointer,"<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->\n@AGENTS.md\n")
 step=ci.fetch('jobs').fetch('invariants').fetch('steps').find{|item| item['name']=='Compatibility pointers must stay intact'}
 invoke=proc{Open3.capture2e('/bin/bash','-c',step.fetch('run'),chdir:temp)}
 output,status=invoke.call
 raise "valid compatibility pointers were refused: #{output}" unless status.success?
 File.write(pointer,"invalid\n")
 output,status=invoke.call
 raise 'broken compatibility pointer was accepted' if status.success?
 File.unlink(pointer)
 File.symlink('AGENTS.md',pointer)
 output,status=invoke.call
 raise 'symlink compatibility pointer was accepted' if status.success?
end
raise 'required job expansion changed' unless ci.fetch('jobs').reject{|id,_| id=='tests-timing-aggregate'}.sum{|_,job| (job.dig('strategy','matrix') || {}).values.map(&:length).inject(1,:*)}==17
puts "ok - #{checks} Linux jobs use hosted routing; required producers propagate failures, separate compliance stays intact, optional aggregate requires real archive paths"
RUBY
