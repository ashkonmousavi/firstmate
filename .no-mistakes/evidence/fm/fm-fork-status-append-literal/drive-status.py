import os, pathlib, subprocess, tempfile, shutil, re, json, time, shlex
root = pathlib.Path.cwd()
evidence = pathlib.Path('~/.no-mistakes/evidence/01M5ED5H2S122JNC1V7V3TSYGS')
fixture = pathlib.Path(tempfile.mkdtemp(prefix='manual-', dir=root / '.test-status-tmp'))
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key.startswith('TASKS_AXI_'):
        env.pop(key)
env['TMPDIR'] = str(fixture)
env['HOME'] = str(fixture / 'user-home')
pathlib.Path(env['HOME']).mkdir()
log=[]
def run(args, data=None, home=None, ok=True):
    e=env.copy()
    if home: e['FM_HOME']=str(home)
    p=subprocess.run([str(x) for x in args],input=data,text=True,capture_output=True,env=e,cwd=root)
    if ok: assert p.returncode==0, (args,p.returncode,p.stdout,p.stderr)
    return p

def show(label, text):
    log.append(label+'\n'+text)
    print(log[-1], flush=True)

try:
    a,b=fixture/'backtick-created',fixture/'substitution-created'
    payload=f'`touch {a}` $(touch {b}) $HOME single\'quote "double" \\ %s'
    # Intent is the oracle: literal text bytes, one line, numeric current epoch.
    for kind, opts in [('ship',['sample','--mode','no-mistakes']),('direct',['sample','--mode','direct-PR']),('local',['sample','--mode','local-only']),('scout',['sample','--scout']),('charter',['--secondmate','--no-projects'])]:
        home=fixture / "home with 'quote"
        (home/'state').mkdir(parents=True,exist_ok=True)
        run([root/'bin/fm-brief.sh',kind,*opts],home=home)
        brief=(home/'data'/kind/'brief.md').read_text()
        lines=brief.splitlines()
        start=next(i for i,line in enumerate(lines) if 'fm-status-append.sh' in line)
        end=lines.index('EOF',start)
        command='\n'.join(lines[start:end+1]).replace('{state}','done').replace('{one short line}',payload+'\nsecond line')
        run(['bash','-c',command])
        status=(home/'state'/f'{kind}.status').read_text()
        assert re.fullmatch(r'done \[at=\d+\]: '+re.escape(payload+' second line')+'\n',status),repr(status)
        assert not a.exists() and not b.exists()
        assert 'The report text is data, never shell.' in brief
        show('Generated '+kind+' command executed; stored record:',status.rstrip())
    show('Payload side effects', 'Neither touch marker exists; $HOME, quotes, backslash and percent format text remain literal.')

    home=fixture/'ledger-home'
    for d in ['state','config']: (home/d).mkdir(parents=True)
    (home/'config/fleet-ledger').touch()
    status=home/'state/keyed.status'
    before=int(time.time())
    run([root/'bin/fm-status-append.sh',status,'needs-decision','--corr','corr=0123456789abcdef','--key','api-shape'],data=payload+'\r\nalpha\rbeta\n',home=home)
    text=status.read_text()
    match=re.fullmatch(r'needs-decision \[key=api-shape\] \[corr=0123456789abcdef\] \[at=(\d+)\]: '+re.escape(payload+' alpha beta')+'\n',text)
    assert match and before <= int(match[1]) <= int(time.time())
    ledger=home/'state/fleet-ledger.jsonl'
    rows=[json.loads(x) for x in ledger.read_text().splitlines()]
    assert len(rows)==1 and rows[0]['event']=='task.status' and rows[0]['key']=='api-shape'
    show('Key/corr order, CRLF/CR/LF folding and current timestamp:',text.rstrip())
    show('Ledger immediately after helper append:',ledger.read_text().rstrip())
    run([root/'bin/fm-fleet-ledger.sh','capture'],home=home)
    assert len(ledger.read_text().splitlines())==1
    # Exact old public command shape, only harmless literal payload.
    command='echo "working [at=1790000000]: legacy report" >> '+shlex.quote(str(status))+' && { [ ! -e '+shlex.quote(str(home/'config/fleet-ledger'))+' ] || '+shlex.quote(str(root/'bin/fm-fleet-ledger.sh'))+' appended '+shlex.quote(str(home/'config'))+' '+shlex.quote(str(status))+' >/dev/null 2>&1 || true; }'
    run(['bash','-c',command],home=home)
    run([root/'bin/fm-fleet-ledger.sh','capture'],home=home)
    rows=[json.loads(x) for x in ledger.read_text().splitlines()]
    assert len(rows)==2 and rows[1]['state']=='working' and rows[1]['text']==' legacy report'
    show('Legacy echo append plus capture; no duplicate ledger records:',ledger.read_text().rstrip())

    parent=fixture/'parent'
    (parent/'state').mkdir(parents=True)
    mate=fixture/'mate'
    mate.mkdir()
    (mate/'.fm-secondmate-home').write_text('mate-id\n')
    (mate/'.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={parent}\n')
    corr='0123456789abcdef'
    report=root/'bin/fm-secondmate-report.sh'
    run([report,'done',corr],data=payload+'\nsecond line\n',home=mate)
    run([report,'--doc','done',corr,'data/report.md'],data=payload+'\nsecond line\n',home=mate)
    run([report,'done',corr,payload],home=mate)
    records=(parent/'state/mate-id.status').read_text().splitlines()
    assert len(records)==3
    expected=[payload+' second line (via-helper)',payload+' second line (data/report.md via-helper)',payload+' (via-helper)']
    for line,note in zip(records,expected):
        assert re.fullmatch(r'done \[corr='+corr+r'\] \[at=\d+\]: '+re.escape(note),line),line
    assert not a.exists() and not b.exists()
    show('Second-mate stdin, --doc stdin and legacy argument notes on resolved parent channel:', '\n'.join(records))
    show('Final result','All assertions passed; disposable homes removed on exit.')
finally:
    shutil.rmtree(fixture)
    (evidence/'live-status-transcript.txt').write_text('\n\n'.join(log)+'\n')
