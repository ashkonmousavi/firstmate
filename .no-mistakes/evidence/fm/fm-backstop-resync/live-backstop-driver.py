"""Reproduce backstop CLI behavior with local read-only transport and isolated homes.
Oracle: supplied intent and R1 decision; never imports the backstop implementation.
Actual backstop, fm-on, remote readers and timestamp parser execute unchanged.
Transport failures/stalls/preemption are explicit external-boundary fault injection.
Sending stays disabled so no real pane, inbox, remote host or fleet home is used.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path.cwd()
EVIDENCE = Path(__file__).parent
REPORT = []
TRANSCRIPT = []

ADAPTER = r'''#!/usr/bin/env python3
import base64,json,os,subprocess,sys
from pathlib import Path
args=sys.argv[sys.argv.index('--')+1:]
assert args[0]=='local-backstop-lab', args
assert args[1]=='fm-remote-entrypoint.sh' and args[2]=='1', args
root=Path(base64.b64decode(args[3]).decode())
home=Path(base64.b64decode(args[4]).decode())
argv=[x.decode() for x in base64.b64decode(args[5]).split(b'\0')[:-1]]
assert root==Path(os.environ['LAB_CODE_ROOT'])
assert home==Path(os.environ['LAB_REMOTE_HOME'])
assert argv[0] in ('fm-remote-file.sh','fm-remote-delta-read.sh')
modefile=Path(os.environ['LAB_MODE'])
mode=json.loads(modefile.read_text())
row={'argv':argv}
if mode.get('fail'):
    rc,out,err=1,b'',b'injected transport unavailable\n'
elif argv[0]=='fm-remote-delta-read.sh' and mode.get('preempt',0):
    mode['preempt']-=1
    modefile.write_text(json.dumps(mode))
    rc,out,err=76,b'',b'injected lane preemption\n'
elif argv[0]=='fm-remote-delta-read.sh' and mode.get('stuck'):
    rc=0
    out=('schema=fm-remote-delta.v1\nstatus=delta\nto_offset=%s\npayload_bytes=0\nto_prefix_sha256=%s\n\n' % (argv[2],argv[3])).encode()
    err=b''
else:
    env=dict(os.environ,FM_HOME=str(home))
    proc=subprocess.run([str(root/'bin'/argv[0]),*argv[1:]],env=env,capture_output=True,timeout=10)
    rc,out,err=proc.returncode,proc.stdout,proc.stderr
row['exit']=rc
if argv[0]=='fm-remote-delta-read.sh' and rc==0:
    header=out.partition(b'\n\n')[0].decode()
    row['response']=dict(line.split('=',1) for line in header.splitlines())
if err: row['stderr']=err.decode(errors='replace')
with open(os.environ['LAB_CALLS'],'a') as log: log.write(json.dumps(row)+'\n')
sys.stdout.buffer.write(out)
sys.stderr.buffer.write(err)
sys.exit(rc)
'''

with tempfile.TemporaryDirectory(prefix='.backstop-live-', dir=ROOT) as tmp:
    base=Path(tmp)
    adapter=base/'local-transport'
    adapter.write_text(ADAPTER)
    adapter.chmod(0o755)
    now=int(time.time())
    mirrored=now-5000
    oldest=now-3600
    latest=now-1500

    def create(name, body, record=None):
        area=base/name
        home=area/'home'
        remote=area/'remote'
        for folder in (home/'state',home/'data',home/'config',remote/'state'):
            folder.mkdir(parents=True)
        (remote/'state/parent-replies.status').write_bytes(body)
        (home/'state/.remote-reply-mirrored-q-server').write_text(f'done [at={mirrored}]: mirrored\n')
        (home/'data/secondmates.md').write_text(
            f'- q-server - disposable test mate (host: local-backstop-lab; root: {ROOT}; home: {remote}; scope: testing; projects: none; added 2026-10-28)\n')
        if record is not None:
            (home/'state/.main-backstop.json').write_text(json.dumps({'readers':{'q-server':record}}))
        mode=area/'mode.json'
        mode.write_text('{}')
        env=dict(os.environ)
        for key in tuple(env):
            if key.startswith('FM_') or key.startswith('HERDR_'):
                env.pop(key)
        env.update(FM_HOME=str(home),FM_SSH_BIN=str(adapter),LAB_CODE_ROOT=str(ROOT),
                   LAB_REMOTE_HOME=str(remote),LAB_MODE=str(mode),LAB_CALLS=str(area/'calls.jsonl'),
                   TMPDIR=str(area),PYTHONDONTWRITEBYTECODE='1')
        return {'name':name,'area':area,'home':home,'remote':remote,'mode':mode,'env':env,'passes':[]}

    def run(ctx):
        command=[sys.executable,str(ROOT/'bin/fm-main-backstop.py'),'--home',str(ctx['home']),
                 '--code-root',str(ROOT),'--mate','q-server','--send-enabled-file',
                 str(ctx['home']/'config/main-backstop-send-enabled')]
        result=subprocess.run(command,env=ctx['env'],capture_output=True,text=True,timeout=45)
        assert result.returncode==0, result.stderr
        memory=json.loads((ctx['home']/'state/.main-backstop.json').read_text())
        assert (ctx['area']/'calls.jsonl').exists(), (result.stdout, result.stderr, memory)
        calls=[json.loads(line) for line in (ctx['area']/'calls.jsonl').read_text().splitlines()]
        before=sum(len(p['calls']) for p in ctx['passes'])
        snapshot={'pass':len(ctx['passes'])+1,'command':'python3 bin/fm-main-backstop.py --home <isolated-home> --code-root "$PWD" --mate q-server --send-enabled-file <absent-opt-in>',
                  'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr,
                  'calls':calls[before:],'state':memory}
        ctx['passes'].append(snapshot)
        TRANSCRIPT.append({'scenario':ctx['name'],**snapshot})
        (EVIDENCE/'live-backstop-transcript.json').write_text(json.dumps(TRANSCRIPT,indent=2)+'\n')
        print(ctx['name'],snapshot['pass'],result.stdout.strip().replace('\n',' | '),flush=True)
        return memory,snapshot['calls']

    def finish(ctx, explanation):
        REPORT.append({'name':ctx['name'],'result':'pass','evidence':explanation,'passes':len(ctx['passes'])})
        (EVIDENCE/'live-backstop-results.json').write_text(json.dumps(REPORT,indent=2)+'\n')

    def legacy(body,stamp):
        return {'offset':len(body),'prefix':hashlib.sha256(body).hexdigest(),'stamp':stamp}

    def pending_messages(memory):
        return '\n'.join(memory.get('deferred_alarms',{}).values())

    # Correct tail cursor for the reported log size must avoid whole-file rebootstrap.
    body=f'done [at={mirrored}]: already mirrored\n'.encode()+((b'x'*2047+b'\n')*830)
    assert len(body)>1048576
    ctx=create('legacy-large-cursor',body,legacy(body,mirrored))
    memory,calls=run(ctx)
    assert len(calls)==1 and calls[0]['argv'][0]=='fm-remote-delta-read.sh',calls
    assert calls[0]['argv'][2:4]==[str(len(body)),hashlib.sha256(body).hexdigest()]
    assert memory['readers']['q-server']=={'offset':len(body),'prefix':hashlib.sha256(body).hexdigest(),'pending_at':[]}
    assert not memory['read_fails'] and not memory['episodes']
    finish(ctx,f'Kept {len(body)}-byte cursor and SHA256; one tail delta read, no whole-file get or alarms.')

    body=f'done [at={oldest}]: pending reply\n'.encode()
    ctx=create('legacy-pending-lag-and-clear',body,legacy(body,oldest))
    memory,calls=run(ctx)
    assert memory['readers']['q-server']['pending_at']==[oldest]
    assert f'oldest_at={oldest} ingested_at={mirrored}' in pending_messages(memory)
    assert 'lag-q-server' in memory['episodes'] and not memory['read_fails']
    assert all(c['argv'][0]=='fm-remote-delta-read.sh' for c in calls)
    (ctx['home']/'state/.remote-reply-mirrored-q-server').write_text(f'done [at={oldest}]: mirrored\n')
    memory,calls=run(ctx)
    assert memory['readers']['q-server']['pending_at']==[] and 'lag-q-server' not in memory['episodes']
    finish(ctx,'Migrated pending stamp triggers durable lag; mirroring it clears pending and active lag episode.')

    records=[dict(legacy(body,oldest),version=2),{'offset':len(body),'prefix':hashlib.sha256(body).hexdigest()},
             dict(legacy(body,oldest),offset=-1),dict(legacy(body,oldest),prefix='bogus')]
    records += [dict(legacy(body,oldest),stamp=x) for x in (-1,True,False,float(oldest),str(oldest),None,[],{})]
    for i,record in enumerate(records):
        ctx=create('invalid-legacy-'+str(i),body,record)
        memory,calls=run(ctx)
        assert calls[0]['argv'][0]=='fm-remote-file.sh',calls
        assert memory['readers']['q-server']['pending_at']==[oldest]
        assert f'oldest_at={oldest}' in pending_messages(memory) and not memory['read_fails']
        finish(ctx,'Invalid shape/stamp bypasses migration, rebuilds through real whole-file reader and reports oldest lag.')

    ctx=create('bogus-valid-hash-continuity',body,{'offset':len(body),'prefix':'0'*64,'stamp':oldest})
    memory,calls=run(ctx)
    assert [c['argv'][0] for c in calls]==['fm-remote-delta-read.sh','fm-remote-file.sh']
    assert calls[0]['response']['status']=='continuity-broken'
    assert memory['readers']['q-server']=={'offset':len(body),'prefix':hashlib.sha256(body).hexdigest(),'pending_at':[oldest]}
    assert f'oldest_at={oldest}' in pending_messages(memory)
    finish(ctx,'Validly shaped but false prefix produces continuity-broken, then rebuilds before reporting lag.')

    # The first four windows contain only a mirrored stamp; real lag lies later.
    body=(f'done [at={mirrored}]: mirrored head\n'.encode()+((b'a'*2047+b'\n')*150)
          +f'done [at={oldest}]: oldest pending\n'.encode()+((b'b'*2047+b'\n')*690)
          +f'done [at={latest}]: newest pending\n'.encode())
    assert len(body)>1700000
    ctx=create('cold-large-backlog',body)
    offsets=[]
    for n in range(10):
        memory,calls=run(ctx)
        offset=memory['readers']['q-server']['offset']
        assert not memory['read_fails'] and 'read-q-server' not in memory['episodes']
        assert 'REPLY DELIVERY UNVERIFIED' not in pending_messages(memory)
        assert len([c for c in calls if c['argv'][0]=='fm-remote-delta-read.sh'])<=4
        if not n:
            assert calls[0]['stderr'].find('file exceeds max-bytes')>=0,calls
            assert 'catching up' in ctx['passes'][-1]['stdout']
            assert memory['readers']['q-server']['pending_at']==[]
        offsets.append(offset)
        if offset==len(body):break
    assert offsets[-1]==len(body) and all(b>a for a,b in zip([0]+offsets,offsets))
    assert memory['readers']['q-server']['prefix']==hashlib.sha256(body).hexdigest()
    assert f'oldest_at={oldest} ingested_at={mirrored}' in pending_messages(memory)
    finish(ctx,f'Cold {len(body)}-byte resync refused whole-file get and converged in {len(offsets)} passes at offsets {offsets}; real oldest lag retained with zero read failures/unverified alarms.')

    small=f'done [at={mirrored}]: mirrored\n'.encode()
    for name,mode in [('stalled-budget',{'stuck':True}),('transport-failure',{'fail':True}),('permanent-preemption',{'preempt':100})]:
        ctx=create(name,small,{'offset':len(small),'prefix':hashlib.sha256(small).hexdigest(),'pending_at':[]})
        ctx['mode'].write_text(json.dumps(mode))
        memory,calls=run(ctx)
        assert 'q-server' in memory['read_fails'] and 'read-q-server' not in memory['episodes']
        if name!='transport-failure':assert len(calls)==4
        memory,calls=run(ctx)
        assert 'read-q-server' in memory['episodes']
        assert 'REPLY DELIVERY UNVERIFIED q-server' in pending_messages(memory)
        assert memory['readers']['q-server']['offset']==len(small)
        if name!='transport-failure':assert len(calls)==4
        ctx['mode'].write_text('{}')
        memory,calls=run(ctx)
        assert not memory['read_fails'] and 'read-q-server' not in memory['episodes']
        finish(ctx,'First failure tolerated; second pass records durable UNVERIFIED; real healthy tail read clears active read failure. Four calls per stalled/preempted pass, one per transport failure.')

    ctx=create('bounded-preemption-retry',small,{'offset':len(small),'prefix':hashlib.sha256(small).hexdigest(),'pending_at':[]})
    body=small+f'done [at={oldest}]: real pending append\n'.encode()
    (ctx['remote']/'state/parent-replies.status').write_bytes(body)
    ctx['mode'].write_text(json.dumps({'preempt':3}))
    memory,calls=run(ctx)
    assert [c['exit'] for c in calls[:3]]==[76]*3
    assert len({tuple(c['argv'][2:4]) for c in calls[:4]})==1
    assert memory['readers']['q-server']['offset']==len(body) and not memory['read_fails']
    assert f'oldest_at={oldest}' in pending_messages(memory)
    finish(ctx,'Three preemptions retry exactly the same cursor; fourth attempt executes real reader and reports lag without read failure.')

# TemporaryDirectory has removed every fixture. No child or pane was detached.
(EVIDENCE/'live-backstop-transcript.json').write_text(json.dumps(TRANSCRIPT,indent=2)+'\n')
(EVIDENCE/'live-backstop-results.json').write_text(json.dumps(REPORT,indent=2)+'\n')
print('All disposable CLI scenarios passed; fixtures removed.',flush=True)
