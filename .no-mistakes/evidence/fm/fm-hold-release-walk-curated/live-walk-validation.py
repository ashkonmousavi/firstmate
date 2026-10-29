import os, pathlib, subprocess, tempfile, shutil, json, time, signal, hashlib
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M63C7BBG117KTXSCWYQZZ9EG')
log=(E/'live-walk-transcript.log').open('w',buffering=1)
results=[]; labs=[]
base={k:v for k,v in os.environ.items() if not k.startswith('FM_') and not k.startswith('TASKS_AXI_') and k not in ('TMUX','TMUX_TMPDIR')}
base['TMPDIR']='/tmp'
def run(args,home=None,extra=None,ok=(0,),timeout=45,stdin=None):
    env=base.copy()
    if home: env['FM_HOME']=str(home)
    if extra: env.update(extra)
    cmd=[str(x) for x in args]
    log.write('$ '+ ' '.join(cmd)+('\nFM_HOME='+str(home) if home else '')+'\n')
    p=subprocess.run(cmd,cwd=ROOT,env=env,input=stdin,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout)
    log.write(p.stdout+'\nexit='+str(p.returncode)+'\n')
    if ok is not None: assert p.returncode in ok, (cmd,p.returncode,p.stdout)
    return p

def home():
    p=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.')); labs.append(p)
    run(['bin/fm-lab-home.sh','create',p])
    (p/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (p/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    return p

def axi(h,*args,**kw): return run(['bin/fm-tasks-axi.sh',*args],h,**kw)
def evaluate(h):
    return run(['bash','-c','. bin/fm-hold-release-lib.sh; fm_hold_release_evaluate "$FM_HOME/state"'],h)
def decisions(h,id):
    return run(['bash','-c','. bin/fm-classify-lib.sh; status_open_decisions "$FM_HOME/state/$1.status"','_',id],h).stdout

def snapshot(h,path,label):
    data=(h/path).read_text(); log.write('PERSISTED '+str(h/path)+'\n'+data+'\n')
    (E/label).write_text(data); return data

def scenario(name,fn):
    log.write('\nSCENARIO '+name+'\n')
    try:
        fn(); results.append({'name':name,'result':'pass'})
    except Exception as ex:
        log.write('FAIL '+repr(ex)+'\n'); results.append({'name':name,'result':'fail','error':repr(ex)})

try:
    # The runbook authorizes a marked throwaway home and its private tmux socket.
    parent=home(); mate=home()
    socket=parent/'tmux'; socket.mkdir()
    tenv={'TMUX_TMPDIR':str(socket),'FM_SEND_SETTLE':'0','FM_SEND_SLEEP':'0','FM_SEND_RETRIES':'1'}
    run(['tmux','-L','fm-lab','-f','/dev/null','new-session','-d','-s','fm-lab-walk','-n','fm-mate','-x','100','-y','30','-c',ROOT],parent,tenv)
    try:
        (mate/'.fm-secondmate-home').write_text('mate\n')
        (mate/'.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={parent}\n')
        (parent/'state/mate.meta').write_text(f'kind=secondmate\nharness=claude\nbackend=tmux\nwindow=fm-lab-walk:fm-mate\nhome={mate}\nworktree={ROOT}\n')
        briefs=mate/'data/walk-briefs'; briefs.mkdir(); brief=briefs/'brief.md'
        brief.write_text('Exercise the disposable test checkpoint and report the observed outcome.\n')
        release='0dc10300c6ac2abcadefc8f9661c91f63650528a'
        def carrier_guards():
            for bad in ['relative.md',str(parent/'config/forbidden.md')]:
                run(['bin/fm-walk-request.sh','--brief',bad,'--release',release,'--walks','live-walk'],mate,ok=(2,))
            assert not (parent/'state/mate.status').exists()
        scenario('The walk carrier refuses relative and private briefs without publishing a request',carrier_guards)
        def walk_missing():
            out=run(['bin/fm-walk-request.sh','--brief',brief,'--release',release,'--walks','live-walk','--bot','LabWalker'],mate).stdout
            assert 'once-key=live-walk@'+release in out
            snapshot(parent,'state/mate.status','walk-parent-channel.txt')
            run(['bin/fm-walk-request-check.sh','arm'],parent,tenv)
            assert (parent/'state/walk-request.check-trust').exists()
            assert not (parent/'data/bin/fm-grok-bot-dispatch.sh').exists()
            for _ in range(5):
                run(['bin/fm-walk-request-check.sh','check'],parent,tenv)
                msgs=list((parent/'state/mate.inbox').glob('*.msg'))
                if msgs: break
            assert msgs,'real fm-send must return the unavailable-dispatcher outcome to the mate inbox'
            message=msgs[0].read_text(); log.write('RETURNED INBOX RECORD\n'+message+'\n')
            assert 'no walker dispatcher' in message and 'walk was not dispatched' in message,message
            (E/'walk-returned-inbox.txt').write_text(message)
            count=len(msgs)
            for _ in range(3): run(['bin/fm-walk-request-check.sh','check'],parent,tenv)
            assert len(list((parent/'state/mate.inbox').glob('*.msg')))==count
            run(['tmux','-L','fm-lab','capture-pane','-p','-t','fm-lab-walk:fm-mate'],parent,tenv)
            run(['bin/fm-walk-request-check.sh','disarm'],parent,tenv)
        scenario('A mate request reaches the registered check and a missing-dispatcher outcome returns once through the real steering inbox',walk_missing)
        def inline_remote():
            (mate/'.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=main\n')
            data=('Remote café brief\n'.encode()+b'x'*65536)[:65536]
            brief.write_bytes(data)
            run(['bin/fm-walk-request.sh','--brief',brief,'--release',release,'--walks','remote','--bot','LabWalker'],mate)
            channel=(mate/'state/parent-replies.status').read_bytes()
            assert len(channel)>65536
            delta=run(['bin/fm-remote-delta-read.sh','state/parent-replies.status','0',hashlib.sha256(b'').hexdigest(),'0'],mate).stdout
            header,payload=delta.split('\n\n',1)
            fields=dict(line.split('=',1) for line in header.splitlines())
            assert fields['status']=='delta'
            assert payload.encode()==channel
            assert int(fields['payload_bytes'])==len(channel)
            assert fields['payload_sha256']==hashlib.sha256(channel).hexdigest()
            brief.write_bytes(data+b'x')
            run(['bin/fm-walk-request.sh','--brief',brief,'--release',release,'--walks','remote','--bot','LabWalker'],mate,ok=(2,))
            assert (mate/'state/parent-replies.status').read_bytes()==channel
            (E/'remote-inline-result.json').write_text(json.dumps({'brief_bytes':len(data),'channel_bytes':len(channel),'remote_delta':fields,'exact_payload_match':True,'oversize_refused_without_append':True},indent=2)+'\n')
        scenario('A maximum 64 KiB remote brief crosses the real delta reader intact; oversized briefs refuse without publishing',inline_remote)
    finally:
        run(['tmux','-L','fm-lab','kill-server'],parent,tenv,ok=None)
finally:
    for p in labs:
        shutil.rmtree(p)
    log.write('CLEANUP: all disposable lab homes removed; private tmux server stopped.\n')
    (E/'live-walk-results.json').write_text(json.dumps(results,indent=2)+'\n')
    log.close()
print(json.dumps(results,indent=2))
raise SystemExit(1 if any(x['result']=='fail' for x in results) else 0)
