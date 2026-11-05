import os, re, pathlib, subprocess, shutil
root=pathlib.Path.cwd()
evidence=pathlib.Path(__file__).resolve().parent
scratch=root/'.test-phase-regression'
cases={
 'fm-backlog-atomicity':['test_scout_phase_retention_replays_without_worker_metadata','test_scout_phase_declaration_grammar','test_scout_phase_done_preserves_the_parent_row','test_scout_phase_json_completion'],
 'fm-teardown':['test_scout_phase_cleanup_retains_its_owner_and_dependencies'],
 'fm-branch-supervision':['test_branch_prompt_routes_completed_scouts_through_guarded_cleanup']}
paths=[]
try:
 (scratch/'tmp').mkdir(parents=True,exist_ok=False)
 for name, selected in cases.items():
  source=(root/'tests'/f'{name}.test.sh').read_text()
  source='\n'.join(line for line in source.splitlines() if not re.fullmatch('test_[a-zA-Z0-9_]+',line))+'\n'
  path=root/'tests'/f'.test-phase-{name}.test.sh'
  if path.exists(): raise RuntimeError(f'Existing transient test: {path}')
  path.write_text(source+'\n'.join(selected)+'\n'); paths.append(path)
 env=os.environ.copy();env['TMPDIR']=str(scratch/'tmp')
 with (evidence/'targeted-regressions.log').open('w') as log:
  result=subprocess.run(['bash','bin/fm-test-run.sh',*[str(path.relative_to(root)) for path in paths],'--json',str(evidence/'targeted-timing.json')],env=env,stdout=log,stderr=subprocess.STDOUT)
 raise SystemExit(result.returncode)
finally:
 for path in paths: path.unlink(missing_ok=True)
 if scratch.exists(): shutil.rmtree(scratch)
