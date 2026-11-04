import json, os, pathlib, shutil, subprocess
root=pathlib.Path.cwd(); ev=pathlib.Path('~/.no-mistakes/evidence/01M6HVSX6XW3XZP10BEN54C09Z'); home=root/'.test-phase-tmp/stop-replay'
home.mkdir();(home/'state').mkdir();(home/'config').mkdir()
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') and k.endswith('_OVERRIDE'))};env.update(FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'))
source=json.loads((ev/'live-guard.json').read_text())[0]['events'][0]['payload']
source['transcript_path']=str(ev/'incident-no-read-transcript-1.jsonl')
log=[]
def run(name,message,expected,active=False):
    payload={**source,'session_id':'native-replay','last_assistant_message':message,'stop_hook_active':active}
    p=subprocess.run(['python3','-B',str(root/'bin/fm-state-claim-guard.py')],env=env,input=json.dumps(payload),capture_output=True,text=True)
    log.append({'case':name,'payload':payload,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    assert p.returncode==expected,(name,p)
try:
    run('capacity retry stays blocked','Laptop 8 live of 8, admission no.',2,True)
    for prefix in ('','👉 ','- ','1. '):
        run('mixed assertion cannot borrow question exemption',prefix+'PC has 2 free; should I fill them?',2)
        run('pure question remains allowed',prefix+'How many lanes are free?',0)
    (home/'config/reply-shape').write_text('ask-first\npacific-times\npr-urls\n')
    for name,message in [('ask-first','The task is done. Should I proceed?'),('pacific-times','The task finished at 12:30 UTC.'),('pr-urls','PR #219 is ready.')]:
        run('configured '+name+' policy blocks',message,2)
    run('configured permitted prose','👉 **Proceed?** A) Continue',0)
finally:
    (ev/'native-stop-replay.json').write_text(json.dumps(log,indent=2));shutil.rmtree(home)
print('PASS: capacity retry and mixed questions stay blocked; pure formatted questions and correctly configured prose remain allowed; configured reply policies execute')
