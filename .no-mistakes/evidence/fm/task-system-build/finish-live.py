from pathlib import Path
E=Path('~/.no-mistakes/evidence/01M6NY9S7GT8ZQD7TVD95RD89G')
exec((E/'live-driver.py').read_text().split('ship=lambda proj:')[0])
results=json.loads((E/'live-results.json').read_text())
for result in results:
 if result['passed'] is False:
  src=Path(result['log']); dest=src.with_suffix('.setup.log'); src.rename(dest)
  result['log']=str(dest); result['setup_attempt']=True
for id,repo,kind in [('unlisted-no-validator','other','ship'),('observe-no-validator','proj','ship'),('no-policy','proj','ship'),('scout','proj','scout')]:
 p=subprocess.run([str(ROOT/'bin/fm-tasks-axi.sh'),'add',id,'Disposable live check','--repo',repo,'--kind',kind,'--body','Missing metadata deliberately','--queue'],env=env,text=True,capture_output=True)
 assert p.returncode==0,p.stdout+p.stderr
ship=lambda proj: [str(LAB/proj),'--mode','direct-PR','--yolo','off']
spy=LAB/'must-not-run.py'
policy(); brief('unlisted-no-validator'); call('unlisted-no-validator',ship('other'),True,validator=LAB/'absent.py')
policy('observe'); brief('observe-no-validator'); call('observe-no-validator',ship('proj'),True,'not readable',LAB/'absent.py')
policy(None); brief('no-policy'); call('no-policy',ship('proj'),True,validator=spy)
assert not (LAB/'unexpected-gate-call').exists()
policy(); brief('scout'); call('scout',[str(LAB/'proj'),'--scout'],True,validator=spy)
assert not (LAB/'unexpected-gate-call').exists()
# Seeded supervisor homes cannot nest under their source checkout. Deploy an
# unchanged copy of the executable files inside this disposable workspace so
# the source and supervisor homes are siblings and both remain in the worktree.
e=env.copy(); e['FM_SLICE_VALIDATOR']=str(spy)
cmd=[str(LAB/'deployment/bin/fm-spawn.sh'),'supervisor',str(LAB/'supervisor-home'),'--secondmate']
p=subprocess.run(cmd,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=110)
(E/'supervisor.log').write_text('$ '+' '.join(cmd)+'\n'+p.stdout+'\nEXIT_STATUS='+str(p.returncode)+'\n')
proof={'id':'supervisor','exit':p.returncode,'meta_exists':(HOME/'state/supervisor.meta').exists(),'passed':p.returncode==0 and (HOME/'state/supervisor.meta').exists() and not (LAB/'unexpected-gate-call').exists(),'log':str(E/'supervisor.log')}
results.append(proof); (E/'live-results.json').write_text(json.dumps(results,indent=2)); print(json.dumps(proof),flush=True)
(E/'bypass-consultation.json').write_text(json.dumps({'validator_invocations_for_relaunch_no_policy_scout_supervisor':int((LAB/'unexpected-gate-call').exists())}))
