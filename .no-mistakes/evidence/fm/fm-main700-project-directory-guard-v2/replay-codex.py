import pathlib,subprocess,json,os
root=pathlib.Path.cwd();ev=pathlib.Path('/home/tegris/.no-mistakes/evidence/01M49D1DVEJXN3RZT15AD8YR2G')
payloads=[json.loads(x) for x in (ev/'codex-final-payloads.jsonl').read_text().splitlines()]
check=root/'.gate-cd-validation/product/bin/fm-cd-pretool-check.sh'
records=[]
for payload,effective_cwd,expected_original,expected_correct in [(payloads[0],payloads[0]['cwd']+'/bin',0,2),(payloads[1],payloads[1]['cwd']+'/outside',2,0)]:
    env=os.environ.copy();env['FM_HOME']=payload['cwd']
    original=subprocess.run([str(check),'--claude'],input=json.dumps(payload),capture_output=True,text=True,env=env,cwd=root)
    corrected=subprocess.run([str(check),'--claude','--cwd',effective_cwd],input=json.dumps(payload),capture_output=True,text=True,env=env,cwd=root)
    assert original.returncode==expected_original
    assert corrected.returncode==expected_correct
    records.append({'native_payload':payload,'effective_execution_cwd_from_native_log':effective_cwd,'original':{'exit':original.returncode,'stdout':original.stdout,'stderr':original.stderr},'only_cwd_corrected':{'exit':corrected.returncode,'stdout':corrected.stdout,'stderr':corrected.stderr}})
(ev/'codex-cwd-boundary-replay.json').write_text(json.dumps(records,indent=2)+'\n')
print('Captured native payloads reproduced both wrong verdicts; correcting only cwd reversed both to the intended verdicts.')
