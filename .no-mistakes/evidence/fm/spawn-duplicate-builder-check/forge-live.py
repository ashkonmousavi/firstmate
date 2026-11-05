import os, pathlib, subprocess, json, time, socket, urllib.request, base64, traceback
ROOT=pathlib.Path.cwd(); D=ROOT/'.test-live'; E=pathlib.Path('~/.no-mistakes/evidence/01M6P6CGV28DT78F2NZW37QR91')
ENV=dict(os.environ)
for k in list(ENV):
    if k.startswith(('FM_', 'HERDR_', 'TASKS_AXI_')) or k in ('TMUX','TMUX_PANE','REX_SESSION','REX_BLOCK','TERM_PROGRAM'):
        ENV.pop(k,None)
ENV.update(HOME=str(D/'user'), XDG_CONFIG_HOME=str(D/'user/config'), XDG_DATA_HOME=str(D/'user/data'), XDG_CACHE_HOME=str(D/'user/cache'), GIT_CONFIG_GLOBAL=str(D/'user/gitconfig'), GIT_CONFIG_NOSYSTEM='1', PATH=str(D/'bin')+':'+ENV['PATH'])
for p in ('user','server','server/data','server/log','lab'):(D/p).mkdir(parents=True,exist_ok=True)
log=(E/'forgejo-live-transcript.log').open('w', buffering=1)
def note(s): print(s,flush=True); log.write(s+'\n')
def run(args, *, env=None, cwd=ROOT, check=True):
    p=subprocess.run([str(a) for a in args],env=env or ENV,cwd=cwd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    if check and p.returncode: raise RuntimeError(f'{args}: exit {p.returncode}: {p.stdout}')
    return p
s=socket.socket();s.bind(('127.0.0.1',0));PORT=s.getsockname()[1];s.close(); URL=f'http://127.0.0.1:{PORT}'
conf=D/'server/app.ini'
conf.write_text(f'''APP_NAME = Disposable duplicate-builder lab
RUN_USER = {os.environ.get('USER','tegris')}
WORK_PATH = {D}/server
[server]
PROTOCOL = http
HTTP_ADDR = 127.0.0.1
HTTP_PORT = {PORT}
ROOT_URL = {URL}/
APP_DATA_PATH = {D}/server/data
DISABLE_SSH = true
OFFLINE_MODE = true
[database]
DB_TYPE = sqlite3
PATH = {D}/server/data/forgejo.db
[repository]
ROOT = {D}/server/repos
[security]
INSTALL_LOCK = true
[service]
DISABLE_REGISTRATION = true
[log]
MODE = file
ROOT_PATH = {D}/server/log
LEVEL = Warn
[api]
MAX_RESPONSE_ITEMS = 2
DEFAULT_PAGING_NUM = 2
''')
fargs=[D/'bin/forgejo','--work-path',D/'server','--config',conf]
server=None
try:
    run(fargs+['migrate'])
    run(fargs+['admin','user','create','--username','labuser','--password','DisposableLab-12345','--email','lab@example.invalid','--admin','--must-change-password=false'])
    out=(E/'forgejo-server.log').open('w')
    server=subprocess.Popen([str(a) for a in fargs+['web']],env=ENV,cwd=ROOT,stdout=out,stderr=subprocess.STDOUT)
    basic='Basic '+base64.b64encode(b'labuser:DisposableLab-12345').decode()
    def api(path, data=None, method=None):
        req=urllib.request.Request(URL+'/api/v1'+path,data=json.dumps(data).encode() if data is not None else None,method=method,headers={'Authorization':basic,'Content-Type':'application/json'})
        with urllib.request.urlopen(req,timeout=15) as r:return json.load(r)
    for _ in range(100):
        try: v=api('/version'); break
        except Exception: time.sleep(.2)
    else: raise RuntimeError('Forgejo did not become ready')
    note('REAL SERVER: '+json.dumps(v)+'; api page cap=2; loopback-only isolated SQLite instance')
    token=api('~/tokens',{'name':'lab','scopes':['all']})['sha1']
    run([D/'bin/tea','login','add','--name','lab','--url',URL,'--token',token])
    note('REAL CLIENT: '+run([D/'bin/tea','--version']).stdout.strip())
    repo=api('/user/repos',{'name':'project','auto_init':True,'default_branch':'main','readme':'Default'})
    project=D/'project';run(['git','clone','--quiet',repo['clone_url'],project])
    # Use the real forge's own API to create committed branch heads and PRs.
    def pr(branch,body=''):
        api('/repos/labuser/project/branches',{'new_branch_name':branch,'old_branch_name':'main'})
        api('/repos/labuser/project/contents/'+branch.replace('/','-')+'.txt',{'branch':branch,'message':'Lab change','content':base64.b64encode(b'lab change\n').decode()})
        return api('/repos/labuser/project/pulls',{'base':'main','head':branch,'title':'Disposable '+branch,'body':body})
    unrelated=[pr('other-'+str(n),'unrelated') for n in range(3)]
    branchpr=pr('fm/dup-live','No task declaration')
    bodypr=pr('laptop-change','```markdown\n**Task: lab/dup-body**\n```')
    def lookup(task,branch=None,forge='forgejo',origin=None,code=0):
        args=['python3','bin/fm-open-pr-lookup.py','--forge',forge,'--origin',origin or repo['clone_url'],'--branch',branch or 'fm/'+task,'--task-id',task,'--timeout','3']
        p=run(args,check=False);note('$ '+' '.join(str(a) for a in args)+'\n'+p.stdout.strip()+f'\nexit={p.returncode}')
        assert p.returncode==code,p.stdout
        return json.loads(p.stdout)
    v=lookup('dup-live');assert [p['number'] for p in v['prs']]==[branchpr['number']]
    v=lookup('dup-body');assert [p['number'] for p in v['prs']]==[bodypr['number']]
    note('PASS real pagination: target PRs were created after three unrelated PRs and discovered despite server page cap=2')
    v=lookup('absent-task');assert v['prs']==[]
    api('/repos/labuser/project/pulls/'+str(bodypr['number']),{'state':'closed'},'PATCH')
    assert lookup('dup-body')['prs']==[]
    note('PASS real closed PR excluded; no matching PR returns an empty successful result')
    # Marked lab home authorizes the production spawn CLI while all data remains disposable.
    lab=D/'lab'; run(['bash','bin/fm-lab-home.sh','create',lab])
    (lab/'config/lane-capacity').write_text('999999 0\n')
    (lab/'config/machine-admission.json').write_text(json.dumps({'schema':'fm-machine-admission.v1','memory_floor_gib':0,'memory_full_avg60_max':100,'disk_floor_gib':0,'disk_paths':[str(lab)]}))
    (lab/'config/crew-harness').write_text('codex\n');(lab/'config/backend').write_text('tmux\n')
    (lab/'data/projects.md').write_text('- project [direct-PR forge=forgejo] - disposable lab (added 2026-11-05)\n')
    (lab/'state/.last-watcher-beat').touch()
    activity=D/'user/.config/skills-master/.agents/skills/activity/activity.sh'
    activity.parent.mkdir(parents=True,exist_ok=True)
    import shutil
    shutil.copyfile('/mnt/c/Users/Tegri/.codex/skills/activity/activity.sh',activity)
    env=dict(ENV,FM_HOME=str(lab),FM_ROOT_OVERRIDE=str(ROOT),TREEHOUSE_ROOT=str(D/'pool'))
    # No TUI is required for refusals, but the real backend has its own private tmux server.
    sock=str(D/'t')
    run(['tmux','-S',sock,'new-session','-d','-s','lab','-x','120','-y','40','-c',ROOT],env=env)
    pid=run(['tmux','-S',sock,'display-message','-p','#{pid}'],env=env).stdout.strip()
    env['TMUX']=sock+','+pid+',0';env['TMUX_PANE']='%0'
    def spawn(task,*flags,expect=1,contains=None):
        args=['bash','bin/fm-spawn.sh',task,str(project),'--mode','direct-PR','--yolo','off',*flags]
        p=run(args,env=env,check=False);note('$ '+' '.join(str(a) for a in args)+'\n'+p.stdout.strip()+f'\nexit={p.returncode}')
        assert p.returncode==expect,p.stdout
        if contains:assert contains in p.stdout,p.stdout
        if expect==1:
            assert not (lab/'state'/f'{task}.meta').exists()
            assert run(['git','branch','--list','fm/'+task],cwd=project).stdout.strip()==''
            assert not (D/'pool').exists()
            note('POSTCONDITION: no task metadata, task branch, or Treehouse pool was created')
        return p.stdout
    a=spawn('dup-live',contains=branchpr['html_url']);b=spawn('dup-live',contains=branchpr['html_url'])
    assert a==b,'replay differs'
    api('/repos/labuser/project/pulls/'+str(bodypr['number']),{'state':'open'},'PATCH')
    spawn('dup-body',contains=bodypr['html_url'])
    spawn('dup-body','--continue-pr',str(bodypr['number']),contains='not this task\'s branch')
    spawn('dup-local','--mode','local-only','--continue-pr','999',contains='local-only has none')
    note('PASS real spawn refusal/replay/body/foreign-branch/local-only attachment boundary')
    # Forge shutdown is an actual unavailable service, rather than a fake reader.
    server.terminate();server.wait(timeout=20);server=None
    lookup('dup-live',code=3)
    spawn('dup-live',contains='UNKNOWN')
    note('PASS unavailable actual forge refuses as UNKNOWN with no task state')
    # Retain necessary lab connection settings for additional live spawn checks, no tokens in evidence.
    (D/'lab-env.json').write_text(json.dumps({'env':env,'socket':sock,'project':str(project),'lab':str(lab),'branch_pr':branchpr,'fargs':[str(a) for a in fargs]}))
except Exception:
    note(traceback.format_exc());raise
finally:
    if 'sock' in locals():
        p=run(['tmux','-S',sock,'kill-server'],env=env,check=False);note('private tmux cleanup exit='+str(p.returncode))
    if server is not None:server.terminate();server.wait(timeout=20)
    note('Forgejo server stopped; all children awaited')
    log.close()
