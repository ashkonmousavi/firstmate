from pathlib import Path
E=Path('~/.no-mistakes/evidence/01M6NY9S7GT8ZQD7TVD95RD89G')
exec((E/'live-driver.py').read_text().split('ship=lambda proj:')[0])
results=json.loads((E/'live-results.json').read_text())
ship=lambda proj: [str(LAB/proj),'--mode','direct-PR','--yolo','off']
def task(id,body):
 p=subprocess.run([str(ROOT/'bin/fm-tasks-axi.sh'),'add',id,'Disposable adversarial check','--repo','proj','--kind','ship','--body',body,'--queue'],env=env,text=True,capture_output=True)
 assert p.returncode==0,p.stdout+p.stderr
policy()
task('missing-task-line','No slice declared'); brief('missing-task-line','SLICE: ops/demo | demo outcome')
call('missing-task-line',ship('proj'),False,'missing-slice (task:missing-task-line)')
task('missing-prep-line','SLICE: ops/demo | demo outcome'); brief('missing-prep-line','SLICE: ops/demo | demo outcome')
(HOME/'data/missing-prep-line/prep.md').write_text('No metadata in this required prep\n')
call('missing-prep-line',ship('proj'),False,'missing-slice')
catalog=json.loads((LAB/'catalog.json').read_text()); other=dict(catalog['slices'][0],id='ops/other'); catalog['slices'].append(other); (LAB/'catalog.json').write_text(json.dumps(catalog))
task('conflicting-prep','SLICE: ops/demo | demo outcome'); brief('conflicting-prep','SLICE: ops/demo | demo outcome')
(HOME/'data/conflicting-prep/prep.md').write_text('SLICE: ops/other | different accepted outcome\n')
call('conflicting-prep',ship('proj'),False,'conflicting-slice')
task('unknown-slice','SLICE: ops/ghost | unaccepted outcome'); brief('unknown-slice','SLICE: ops/ghost | unaccepted outcome')
call('unknown-slice',ship('proj'),False,'dangling-slice')
task('validator-no-result','SLICE: ops/demo | demo outcome'); brief('validator-no-result','SLICE: ops/demo | demo outcome')
crash=LAB/'crash-validator.py'; crash.write_text('raise SystemExit(2)\n')
call('validator-no-result',ship('proj'),False,'could not check',crash)
assert all(x['passed'] for x in results if not x.get('setup_attempt'))
